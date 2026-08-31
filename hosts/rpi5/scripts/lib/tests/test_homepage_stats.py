"""homepage-stats: 20 fetchers that used to run on exactly one machine.

The blast radius here is low — a bug shows a wrong number on a dashboard — so
these tests are weighted differently from the destructive units: the machinery
(cache schema, backfill, error isolation, routing) plus the fetchers whose
arithmetic has actually been wrong before, each of which carries a comment in the
source saying so:

  * wakapi's NANOSECOND durations (/3.6e12)
  * airtrail's SECOND flight durations (/3600, not /60 — that reported 7922 hours
    for 29 flights)
  * ryot's MINUTE rollup with the Steam playtime dump subtracted
  * showmycards' foil-aware EUR value, and cards = SUM(quantity) not COUNT(*)
  * gramps-web summing across every tree
"""

import datetime
import json
import time

import pytest

from nicos_scripts.homepage import stats as hs


class FakeRun:
    """Stands in for subprocess: matches a command by substring, returns text.

    Records every argv, so a test can assert `-readonly` was passed (reading a
    service's live SQLite without it creates root-owned -wal files) or that a
    fetcher never talked to a service it should not wake.
    """

    def __init__(self, answers=None):
        self.answers = list(answers or [])  # [(substring, output)]
        self.calls = []

    def __call__(self, argv, env=None):
        self.calls.append((list(argv), env))
        joined = " ".join(argv)
        for needle, out in self.answers:
            if needle in joined:
                return out(joined) if callable(out) else out
        raise AssertionError(f"unexpected command: {joined}")

    @property
    def commands(self):
        return [" ".join(c[0]) for c in self.calls]


CFG = hs.Config(
    curl="CURL", sqlite="SQLITE", psql="PSQL", runuser="RUNUSER",
    beszel_db="/db/beszel", karakeep_db="/db/karakeep", papra_db="/db/papra",
    vaultwarden_db="/db/vw", wakapi_db="/db/wakapi",
    beaverhabits_db="/db/habits", showmycards_db="/db/smc",
    gramps_trees_glob="/db/gramps/*/sqlite.db",
)


# ── Config ────────────────────────────────────────────────────────────────────


def test_every_path_is_overridable_from_the_environment():
    # The whole point of the migration: thirteen DB paths were module constants,
    # so the file only ran on one machine.
    cfg = hs.Config.from_env({
        "KARAKEEP_DB": "/tmp/k.db", "PAPRA_DB": "/tmp/p.db",
        "BESZEL_DB": "/tmp/b.db", "WAKAPI_DB": "/tmp/w.db",
        "VAULTWARDEN_DB": "/tmp/v.db", "BEAVERHABITS_DB": "/tmp/h.db",
        "SHOWMYCARDS_DB": "/tmp/s.db", "OWUI_DB": "/tmp/o.db",
        "GRAMPS_TREES_GLOB": "/tmp/g/*.db", "SQLITE_BIN": "/bin/sq",
        "STATE_DIRECTORY": "/tmp/state",
    })
    assert cfg.karakeep_db == "/tmp/k.db"
    assert cfg.showmycards_db == "/tmp/s.db"
    assert cfg.sqlite == "/bin/sq"
    assert cfg.state_file == "/tmp/state/stats.json"


def test_the_defaults_are_still_the_live_paths():
    cfg = hs.Config.from_env({})
    assert cfg.karakeep_db == "/var/lib/karakeep/db.db"
    assert cfg.state_file == "/var/lib/homepage-stats/stats.json"
    assert cfg.refresh_interval == 86400


def test_every_published_key_has_a_fetcher_and_vice_versa():
    # These were two separate literals; a new widget could be wired into one and
    # forgotten in the other, leaving its tile permanently empty.
    assert set(hs.FETCHERS) == set(hs.Stats.KEYS)


# ── the Stats registry ────────────────────────────────────────────────────────


def test_an_error_is_recorded_beside_the_last_good_values():
    # A failed refresh must not blank a tile.
    stats = hs.Stats()
    stats.set("karakeep", {"bookmarks": 10})
    stats.error("karakeep", "sqlite3: no such table")
    assert stats.get("karakeep") == {"bookmarks": 10, "error": "sqlite3: no such table"}


def test_one_broken_service_does_not_stop_the_others():
    stats = hs.Stats()
    run = FakeRun([("beszel", "boom"), ("karakeep", "7")])

    def explode(cfg, run):
        raise RuntimeError("beszel is down")

    original = hs.FETCHERS["beszel"]
    hs.FETCHERS["beszel"] = explode
    try:
        assert hs.run_fetcher(CFG, run, stats, "beszel") is False
        assert hs.run_fetcher(CFG, run, stats, "karakeep") is True
    finally:
        hs.FETCHERS["beszel"] = original
    assert stats.get("beszel") == {"error": "beszel is down"}
    assert stats.get("karakeep")["bookmarks"] == 7


def test_a_failed_fetcher_is_logged_not_only_recorded():
    # Recording alone is invisible: the entry keeps its last good numbers, the tile
    # renders them, and the `error` beside them is read by nobody. The AFFiNE token
    # died at the 0.27.3 upgrade and the journal had not one line about it.
    stats = hs.Stats()
    stats.set("affine", {"docs": 7867})
    lines = []

    def explode(cfg, run):
        raise RuntimeError("You must sign in first")

    original = hs.FETCHERS["affine"]
    hs.FETCHERS["affine"] = explode
    try:
        hs.run_fetcher(CFG, FakeRun(), stats, "affine", log=lines.append)
    finally:
        hs.FETCHERS["affine"] = original
    assert lines == ["affine fetch failed: You must sign in first"]
    assert stats.get("affine") == {"docs": 7867, "error": "You must sign in first"}


def test_snapshot_is_a_copy():
    stats = hs.Stats()
    stats.set("papra", {"documents": 1})
    snap = stats.snapshot()
    snap["papra"]["documents"] = 999
    assert stats.get("papra") == {"documents": 1}


def test_missing_lists_only_the_empty_keys():
    stats = hs.Stats()
    stats.set("papra", {"documents": 1})
    missing = stats.missing()
    assert "papra" not in missing
    assert len(missing) == len(hs.Stats.KEYS) - 1


# ── cache ─────────────────────────────────────────────────────────────────────


def cfg_state(tmp_path):
    return hs.Config(state_dir=str(tmp_path))


def test_the_cache_round_trips(tmp_path):
    cfg = cfg_state(tmp_path)
    stats = hs.Stats()
    stats.set("papra", {"documents": 384})
    hs.save_cache(cfg, stats, 1234)

    fresh = hs.Stats()
    assert hs.load_cache(cfg, fresh) == 1234
    assert fresh.get("papra") == {"documents": 384}


def test_a_cache_from_an_older_schema_is_discarded(tmp_path):
    # Otherwise a renamed field keeps serving the old shape for up to 24h after
    # the rebuild that changed it.
    cfg = cfg_state(tmp_path)
    (tmp_path / "stats.json").write_text(json.dumps(
        {"_schema": 1, "_fetched_at": 999, "papra": {"docs": 1}}))
    stats = hs.Stats()
    logged = []
    assert hs.load_cache(cfg, stats, log=logged.append) == 0
    assert stats.get("papra") == {}
    assert "refetching all" in logged[0]


def test_a_missing_cache_is_not_an_error(tmp_path):
    logged = []
    assert hs.load_cache(cfg_state(tmp_path), hs.Stats(), log=logged.append) == 0
    assert logged == []


def test_a_corrupt_cache_is_reported_and_ignored(tmp_path):
    cfg = cfg_state(tmp_path)
    (tmp_path / "stats.json").write_text("{truncated")
    logged = []
    assert hs.load_cache(cfg, hs.Stats(), log=logged.append) == 0
    assert "cache load failed" in logged[0]


def test_saving_leaves_no_temp_file_behind(tmp_path):
    cfg = cfg_state(tmp_path)
    hs.save_cache(cfg, hs.Stats(), 1)
    assert not (tmp_path / "stats.json.tmp").exists()


# ── backfill ──────────────────────────────────────────────────────────────────


def test_backfill_only_fetches_the_keys_the_cache_has_no_entry_for(tmp_path):
    # A newly added widget must not wait a full day, and the socket-activated
    # services must not be woken on every restart.
    cfg = hs.Config(state_dir=str(tmp_path), sqlite="SQLITE",
                    karakeep_db="/db/karakeep")
    stats = hs.Stats()
    for key in hs.Stats.KEYS:
        if key != "karakeep":
            stats.set(key, {"cached": 1})
    run = FakeRun([("karakeep", "3")])

    ts = hs.backfill_missing(cfg, run, stats, 500, log=lambda _m: None)
    assert ts == 500  # the original timestamp is preserved
    assert stats.get("karakeep")["bookmarks"] == 3
    assert all("karakeep" in c for c in run.commands)


def test_a_full_cold_cache_backfill_is_dated_now(tmp_path):
    cfg = hs.Config(state_dir=str(tmp_path))
    stats = hs.Stats()
    for key in hs.Stats.KEYS:
        stats.set(key, {"x": 1})
    # Nothing missing -> nothing fetched, timestamp untouched.
    assert hs.backfill_missing(cfg, FakeRun(), stats, 0, log=lambda _m: None) == 0


def test_the_refresh_loop_runs_every_fetcher_and_saves(tmp_path):
    cfg = hs.Config(state_dir=str(tmp_path), refresh_interval=86400)
    stats = hs.Stats()
    ran = []

    original = dict(hs.FETCHERS)
    try:
        for key in list(hs.FETCHERS):
            hs.FETCHERS[key] = (lambda k: lambda cfg, run: ran.append(k) or {"n": 1})(key)
        last = hs.refresh(cfg, FakeRun(), stats, 0, sleep=lambda _s: None, once=True,
                          log=lambda _m: None)
    finally:
        hs.FETCHERS.clear()
        hs.FETCHERS.update(original)
    # Backfill covers all 19, then the loop refreshes all 19 again.
    assert len(ran) == 2 * len(hs.Stats.KEYS)
    assert last > 0
    assert json.loads((tmp_path / "stats.json").read_text())["_schema"] == hs.STATS_SCHEMA


# ── the read-only discipline ───────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("fetcher", "answer"),
    [("beszel", "1"), ("karakeep", "1"), ("papra", "1"), ("vaultwarden", "1"),
     ("wakapi", "1"), ("showmycards", "1")],
)
def test_service_databases_are_read_with_readonly(fetcher, answer):
    # Without -readonly, sqlite3 creates root-owned -wal/-shm files next to a
    # database owned by the service user, which breaks the service.
    run = FakeRun([("SQLITE", answer)])
    hs.FETCHERS[fetcher](CFG, run)
    assert run.calls
    for argv, _env in run.calls:
        assert "-readonly" in argv


# ── the fetchers whose arithmetic has been wrong before ───────────────────────


def test_wakapi_converts_nanoseconds_to_hours():
    one_hour_ns = str(int(3.6e12))
    run = FakeRun([("durations", one_hour_ns)])
    assert hs.fetch_wakapi(CFG, run) == {"today": 1.0, "last_30d": 1.0, "total": 1.0}


def test_wakapi_uses_local_time_for_today():
    # date() on a value carrying a UTC offset yields the UTC date, which shifts
    # "today" by two hours after midnight.
    run = FakeRun([("durations", "0")])
    hs.fetch_wakapi(CFG, run)
    today_sql = run.commands[0]
    assert "date(time, 'localtime') = date('now', 'localtime')" in today_sql


def test_airtrail_treats_flight_duration_as_seconds():
    # /60 reported 7922 "hours" for 29 flights; the real total is 132.
    def answer(cmd):
        if "SUM(duration)" in cmd:
            return "475200"      # 132 h in seconds
        if "visited_country" in cmd:
            return "9"
        return "29"

    assert hs.fetch_airtrail(CFG, FakeRun([("PSQL", answer)])) == {
        "flights": 29, "countries": 9, "hours": 132}


def test_ryot_hours_come_from_the_minute_rollup_minus_the_steam_dump():
    def answer(cmd):
        if "daily_user_activity" in cmd:
            return "600"     # minutes
        if "workout" in cmd:
            return "12"
        return "300"

    out = hs.fetch_ryot(CFG, FakeRun([("PSQL", answer)]))
    assert out == {"seen": 300, "hours": 10, "workouts": 12}
    # The Steam import dumps 5846 h of lifetime playtime onto one day; it and the
    # visual-novel column are subtracted so they cannot swamp everything else.
    assert "- video_game_duration" in " ".join(hs.RYOT_MEDIA_HOURS_SQL.split())
    assert "- visual_novel_duration" in " ".join(hs.RYOT_MEDIA_HOURS_SQL.split())


def test_freereps_reports_distance_in_km_from_metres():
    # distance_walking_running is stored in METRES (units column says "m"):
    # 13960 m alongside 18545 steps is ~0.75 m a step. Passing qty through as-is
    # would have put "13960 km" on the tile.
    def answer(cmd):
        if "distance_walking_running" in cmd:
            return "13960.88"
        if "step_count" in cmd:
            return "18545"
        return "78.4"  # weight_body_mass

    out = hs.fetch_freereps(CFG, FakeRun([("PSQL", answer)]))
    assert out == {"steps": 18545, "km": 14.0, "weight": 78.4}


def test_freereps_day_totals_are_yesterday_not_today():
    # The aggregator refreshes once every 86400s at an arbitrary wall-clock hour,
    # so "today" would be sampled mid-day and then frozen for 24 hours. Yesterday
    # is the last COMPLETE day.
    seen = []

    def answer(cmd):
        seen.append(" ".join(cmd.split()))
        return "1"

    hs.fetch_freereps(CFG, FakeRun([("PSQL", answer)]))
    totals = [c for c in seen if "SUM(qty)" in c]
    assert len(totals) == 2
    for cmd in totals:
        assert "time >= current_date - INTERVAL '1 day'" in cmd
        assert "time < current_date" in cmd


def test_freereps_weight_is_the_last_known_not_a_day_total():
    # Weigh-ins are sparse (146 rows over six years, newest over a month old), so
    # a "yesterday" weight would render 0 almost every day.
    seen = []

    def answer(cmd):
        seen.append(" ".join(cmd.split()))
        return "78.4"

    hs.fetch_freereps(CFG, FakeRun([("PSQL", answer)]))
    weighin = [c for c in seen if "weight_body_mass" in c]
    assert len(weighin) == 1
    assert "ORDER BY time DESC LIMIT 1" in weighin[0]
    assert "current_date" not in weighin[0]


def test_freereps_pins_the_source_on_sums_but_not_on_the_weigh_in():
    # health_metrics already carries two sources ("" and "FreeReps Backfill") and
    # FreeReps only dedups by source priority in its own query layer, so a plain
    # SUM sees every source at once and would double the step count.
    # "Most recent weight" has no such problem, and filtering it there would
    # freeze the tile on the last Apple value once a Withings sync starts writing
    # its own source — the silent-stale-tile failure mode.
    seen = []

    def answer(cmd):
        seen.append(" ".join(cmd.split()))
        return "1"

    hs.fetch_freereps(CFG, FakeRun([("PSQL", answer)]))

    sums = [c for c in seen if "SUM(qty)" in c]
    assert len(sums) == 2
    assert all("source = ''" in c for c in sums)

    weighin = [c for c in seen if "weight_body_mass" in c]
    assert len(weighin) == 1
    assert "source" not in weighin[0]


def test_freereps_never_touches_its_http_api():
    # freereps.service is socket-activated (0 MB at rest). A daily poll against
    # /api/v1/stats would wake it every day and defeat the reason it sleeps, so
    # every stat here must come from Postgres.
    run = FakeRun([("PSQL", "5")])
    hs.fetch_freereps(CFG, run)
    assert run.commands, "fetcher made no calls at all"
    for cmd in run.commands:
        assert "CURL" not in cmd
        assert "8370" not in cmd and "13348" not in cmd
        assert "PSQL" in cmd and "freereps" in cmd


def test_showmycards_counts_the_collection_not_the_catalogue():
    # `cards` is the 171k-printing Scryfall catalogue; counting it reported 171182
    # owned cards. A row in `inventories` is a stack, so cards = SUM(quantity).
    def answer(cmd):
        if "SUM(quantity)" in cmd:
            return "623"
        if "FROM lists" in cmd:
            return "5"
        if "storage_locations" in cmd:
            return "8"
        return "148.87"

    out = hs.fetch_showmycards(CFG, FakeRun([("SQLITE", answer)]))
    assert out == {"cards": 623, "decks": 5, "locations": 8, "value": 148.87}


def test_the_collection_value_is_foil_aware():
    # A foil row priced from prices.eur contributes 0 whenever a printing is
    # foil-only — how an earlier naive sum came out at 125.07 instead of 148.87.
    assert "eur_foil" in hs.SHOWMYCARDS_VALUE_SQL
    assert "eur_etched" in hs.SHOWMYCARDS_VALUE_SQL


def test_gramps_web_sums_across_every_tree():
    run = FakeRun([("SQLITE", "4")])
    out = hs.fetch_gramps_web(CFG, run, find=lambda pattern: ["/db/a.db", "/db/b.db"])
    assert out == {"people": 8, "families": 8, "events": 8}


def test_gramps_web_with_no_trees_reports_zero():
    out = hs.fetch_gramps_web(CFG, FakeRun(), find=lambda pattern: [])
    assert out == {"people": 0, "families": 0, "events": 0}


def test_beaverhabits_reads_the_json_blob_and_skips_archived_habits():
    blob = json.dumps({"habits": [
        {"name": "run", "status": "active",
         "records": [{"day": "2026-08-06", "done": True}, {"day": "2026-08-05", "done": True}]},
        {"name": "old", "status": "archive",
         "records": [{"day": "2026-08-06", "done": True}]},
        {"name": "read", "records": [{"day": "2026-08-05", "done": True},
                                     {"day": "2026-08-04", "done": False}]},
    ]})
    out = hs.fetch_beaverhabits(CFG, FakeRun([("habit_list", blob + "\n")]),
                                today="2026-08-06")
    assert out == {"habits": 2, "done_today": 1, "checkins": 3}


def test_beaverhabits_sums_across_users():
    one = json.dumps({"habits": [{"name": "a", "records": [{"day": "x", "done": True}]}]})
    run = FakeRun([("habit_list", one + "\n" + one + "\n\n")])
    assert hs.fetch_beaverhabits(CFG, run, today="x") == {
        "habits": 2, "done_today": 2, "checkins": 2}


SURE_ROWS = [("WITH food AS", "300.00|66.20"),
             ("accountable_type = 'Depository'", "6640.47|240.47"),
             ("e.amount > 0", "1928.56"),
             ("FROM budgets", "2500.0000")]


def test_sure_reports_cash_spend_and_the_month_budget():
    cfg = hs.Config(psql="PSQL", runuser="RUNUSER")
    run = FakeRun(SURE_ROWS)
    assert hs.fetch_sure(cfg, run) == {
        "cash": "€6,640 (240€)",
        "spend": "€1,929 (+571€)",
        "food": "€66 (+234€)"}


def test_the_cash_bracket_leaves_out_the_livret_a():
    """The Livret A is savings, and it is nearly the whole balance — EUR 6,400
    of EUR 6,716 — so the headline figure badly flatters what is spendable."""
    cfg = hs.Config(psql="PSQL", runuser="RUNUSER")
    run = FakeRun(SURE_ROWS)
    hs.fetch_sure(cfg, run)
    cash_query = next(c for c in run.commands if "accountable_type" in c)
    assert "livret" in cash_query.lower()


def test_food_spend_includes_the_categorys_children():
    """Sure budgets on '0 - Food' but books spend against Groceries etc."""
    cfg = hs.Config(psql="PSQL", runuser="RUNUSER")
    run = FakeRun(SURE_ROWS)
    hs.fetch_sure(cfg, run)
    food_query = next(c for c in run.commands if "WITH food AS" in c)
    assert "parent_id IN" in food_query
    # The category is matched by name, so its numeric prefix is load-bearing:
    # renumbering the categories in Sure silently zeroes the tile otherwise.
    assert "'0 - Food'" in food_query


def test_overspending_the_month_shows_a_negative_remainder():
    cfg = hs.Config(psql="PSQL", runuser="RUNUSER")
    run = FakeRun([("WITH food AS", "300.00|66.20"),
                   ("accountable_type = 'Depository'", "6640.47|240.47"),
                   ("e.amount > 0", "3100.00"),
                   ("FROM budgets", "2500.0000")])
    assert hs.fetch_sure(cfg, run)["spend"] == "€3,100 (-600€)"


def test_sure_spend_excludes_transfers_between_own_accounts():
    """funds_movement is money moving between the user's own accounts.

    Counting it put EUR 2350 of internal moves into a EUR 2500 budget, so a
    month that had really spent 1928 read as almost entirely gone.
    """
    cfg = hs.Config(psql="PSQL", runuser="RUNUSER")
    run = FakeRun(SURE_ROWS)
    hs.fetch_sure(cfg, run)
    spend_query = next(c for c in run.commands if "e.amount > 0" in c)
    assert "t.kind = 'standard'" in spend_query


def test_sure_cash_is_depositories_only():
    """Credit cards are liabilities; investment accounts are not spendable cash."""
    cfg = hs.Config(psql="PSQL", runuser="RUNUSER")
    run = FakeRun(SURE_ROWS)
    hs.fetch_sure(cfg, run)
    cash_query = next(c for c in run.commands if "accountable_type" in c)
    assert "'Depository'" in cash_query and "CreditCard" not in cash_query


def test_sure_never_wakes_the_socket_activated_app():
    """It used to call the REST API, waking Puma for ten minutes a day."""
    cfg = hs.Config(psql="PSQL", runuser="RUNUSER", curl="CURL")
    run = FakeRun(SURE_ROWS)
    hs.fetch_sure(cfg, run)
    assert all("CURL" not in c for c in run.commands)


NET_WORTH_JSON = json.dumps({
    "assets": {"total": 380779.95, "breakdown": [
        {"category": "properties", "value": 338531.0},
        {"category": "investments", "value": 35608.4},
    ]},
    "liabilities": {"total": 314229.0},
})


def wealthfolio_run(perf, basis_row="25827.35|35610.24|39316.91"):
    return FakeRun([
        ("auth/login", ""),
        ("net-worth", NET_WORTH_JSON),
        ("performance/summary", perf),
        ("cost_basis_base", basis_row),
    ])


def wealthfolio_cfg(tmp_path):
    env_file = tmp_path / "env"
    env_file.write_text("HOMEPAGE_VAR_WEALTHFOLIO_PASSWORD=pw\n")
    return hs.Config(curl="CURL", sqlite="SQLITE", env_file=str(env_file),
                     wealthfolio_url="http://wf", state_dir=str(tmp_path))


def test_wealthfolio_reports_cost_basis_as_the_money_put_in(tmp_path):
    """net_contribution is the obvious field and is flat ZERO in holdings mode."""
    run = wealthfolio_run(json.dumps({"returns": {"valueReturn": 0.02240884}}))
    assert hs.fetch_wealthfolio(wealthfolio_cfg(tmp_path), run) == {
        "net_worth": "€66,551 (35,610€)",
        "invested": "€25,827 (+9,783€)",
        "return_30d": "2.24% (+881€)"}


def test_a_loss_is_shown_with_a_minus_not_a_negative_inside_the_brackets(tmp_path):
    run = wealthfolio_run(json.dumps({"returns": {"valueReturn": -0.02}}),
                          basis_row="30000.00|27500.00|39316.91")
    got = hs.fetch_wealthfolio(wealthfolio_cfg(tmp_path), run)
    assert got["invested"] == "€30,000 (-2,500€)"
    assert got["return_30d"] == "-2.00% (-786€)"


def test_the_return_is_pre_formatted_to_two_places_in_percentage_points(tmp_path):
    """homepage's `percent` format divides by 100 and then Intl multiplies back,
    so it renders the raw number at zero decimals — 0.0224 showed as "0%".
    `float` keeps decimals but drops trailing zeros, so a flat 2.2% would lose a
    place. Formatting here is the only way to guarantee exactly two."""
    run = wealthfolio_run(json.dumps({"returns": {"valueReturn": 0.022}}))
    assert hs.fetch_wealthfolio(wealthfolio_cfg(tmp_path), run)["return_30d"].startswith("2.20%")


def test_a_negative_month_keeps_its_sign(tmp_path):
    run = wealthfolio_run(json.dumps({"returns": {"valueReturn": -0.0151}}))
    assert hs.fetch_wealthfolio(wealthfolio_cfg(tmp_path), run)["return_30d"].startswith("-1.51%")


def test_wealthfolio_asks_for_a_thirty_day_window(tmp_path):
    run = wealthfolio_run(json.dumps({"returns": {"valueReturn": 0.01}}))
    hs.fetch_wealthfolio(wealthfolio_cfg(tmp_path), run)
    body = next(c for c in run.commands if "performance/summary" in c)
    assert hs.days_ago(30) in body and hs.today() in body


def test_wealthfolio_reports_no_return_when_the_app_cannot_compute_one(tmp_path):
    """In HOLDINGS mode the API returns null rather than a wrong number.

    A tile field of None renders empty; inventing one from the value delta gave
    -21k for a month that returned +3.75%, because a transfer out of an account
    is indistinguishable from a loss.
    """
    run = wealthfolio_run(json.dumps({"returns": {"valueReturn": None}}))
    assert hs.fetch_wealthfolio(wealthfolio_cfg(tmp_path), run)["return_30d"] is None


def test_wealthfolio_uses_the_app_port_not_the_read_only_vhost(tmp_path):
    """:3700 is the write-refusing nginx front; /performance/summary is a POST."""
    run = wealthfolio_run(json.dumps({"returns": {"valueReturn": 0.01}}))
    hs.fetch_wealthfolio(wealthfolio_cfg(tmp_path), run)
    assert all(":3700" not in c for c in run.commands)


def test_wealthfolio_reads_its_database_read_only(tmp_path):
    """Writing -wal/-shm as root would break the wealthfolio-owned service."""
    run = wealthfolio_run(json.dumps({"returns": {"valueReturn": 0.01}}))
    hs.fetch_wealthfolio(wealthfolio_cfg(tmp_path), run)
    assert any("-readonly" in c for c in run.commands if "cost_basis_base" in c)


def test_forgejo_separates_issues_from_pull_requests():
    def answer(cmd):
        if "is_pull=true" in cmd:
            return "2"
        if "is_pull=false" in cmd:
            return "7"
        return "31"

    assert hs.fetch_forgejo(CFG, FakeRun([("PSQL", answer)])) == {
        "repositories": 31, "issues": 7, "pulls": 2}


def test_affine_counts_docs_and_live_blobs_only():
    def answer(cmd):
        if "workspace_pages" in cmd:
            return "7503"
        if "FROM workspaces" in cmd:
            return "4"
        return "1000"  # blobs

    assert hs.fetch_affine(CFG, FakeRun([("PSQL", answer)])) == {
        "workspaces": 4, "docs": 7503, "storage": 1000}


def test_affine_needs_no_token_and_never_calls_the_api():
    # The regression this replaces: AFFiNE 0.27.3 deleted user access tokens, so the
    # GraphQL POST 401ed and the tile served two-day-old numbers. A fetcher that
    # holds no credential cannot break that way — assert it stays that way, and that
    # `size` is summed only over blobs that are not tombstoned.
    run = FakeRun([("PSQL", "1")])
    hs.fetch_affine(CFG, run)
    assert not any("CURL" in c for c in run.commands)
    assert not any("Bearer" in c for c in run.commands)
    assert any("deleted_at IS NULL" in c for c in run.commands)


# ── Calino: counts over Nextcloud's CalDAV ────────────────────────────────────
#
# The bug class these guard is not arithmetic, it is asking the WRONG QUESTION:
# recurrence and local days. See the block comment above fetch_calino.

# Deliberately served under the /nextcloud webroot the live server uses
# (overwritewebroot), while the fetcher dials /remote.php/dav directly — the paths it
# queries must be rebuilt from the base, not joined from these hrefs.
CALDAV_HOME_XML = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"
               xmlns:cs="http://calendarserver.org/ns/">
  <d:response>
    <d:href>/nextcloud/remote.php/dav/calendars/nsimon/</d:href>
    <d:propstat><d:prop>
      <d:resourcetype><d:collection/></d:resourcetype>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/nextcloud/remote.php/dav/calendars/nsimon/personal/</d:href>
    <d:propstat><d:prop>
      <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
      <c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/nextcloud/remote.php/dav/calendars/nsimon/reminders/</d:href>
    <d:propstat><d:prop>
      <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
      <c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/nextcloud/remote.php/dav/calendars/nsimon/inbox/</d:href>
    <d:propstat><d:prop>
      <d:resourcetype><d:collection/><c:schedule-inbox/></d:resourcetype>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/nextcloud/remote.php/dav/calendars/nsimon/calino-settings/</d:href>
    <d:propstat><d:prop>
      <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>
      <c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/nextcloud/remote.php/dav/calendars/nsimon/calendargooglecom-4/</d:href>
    <d:propstat><d:prop>
      <d:resourcetype><d:collection/><cs:subscribed/></d:resourcetype>
      <c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/></c:supported-calendar-component-set>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>
"""


def multistatus(hrefs):
    """A calendar-query answer. Takes a count (opaque hrefs) or explicit hrefs.

    The task count is an INTERSECTION of two answers by href, so the identities have
    to be controllable, not just the totals.
    """
    if isinstance(hrefs, int):
        hrefs = [f"/o{i}.ics" for i in range(hrefs)]
    body = "".join(
        f"<d:response><d:href>{h}</d:href>"
        f"<d:propstat><d:prop><d:getetag>&quot;{i}&quot;</d:getetag></d:prop>"
        "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
        for i, h in enumerate(hrefs))
    return f'<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">{body}</d:multistatus>'


def calino_cfg(tmp_path):
    env_file = tmp_path / "env"
    env_file.write_text("HOMEPAGE_VAR_NEXTCLOUD_PASSWORD=app-pw\n")
    return hs.Config(curl="CURL", env_file=str(env_file),
                     nextcloud_dav_url="http://nc/remote.php/dav",
                     nextcloud_user="nsimon")


def calino_run(today=2, week=9, pending=None, due=None, dtstart=None, current=None):
    """FakeRun for the five query shapes.

    The task answers are HREF SETS, because "due now" is `pending ∩ (DUE ∪ DTSTART) ∩
    in-range` intersected client-side — SabreDAV will not AND a prop-filter with a
    time-range. The default fixture models one of each interesting kind:

        t1  pending, has DUE, date passed      → counts
        t2  pending, has DTSTART, date passed  → counts
        t3  pending, has DUE, future           → dropped by the time-range
        t4  pending, undated                   → dropped for having no date
        t5  completed, has DUE, date passed    → dropped by the status filter

    Needle ORDER matters: every task body contains "VTODO", so the discriminating
    needles (STATUS / DUE / DTSTART / time-range) must all precede it.
    """
    pending = ["/t1.ics", "/t2.ics", "/t3.ics", "/t4.ics"] if pending is None else pending
    due = ["/t1.ics", "/t3.ics", "/t5.ics"] if due is None else due
    dtstart = ["/t2.ics"] if dtstart is None else dtstart
    # Undated VTODOs match every range (RFC 4791 §9.9), so t4 is in here — which is
    # exactly why the range cannot be the only date test.
    current = ["/t1.ics", "/t2.ics", "/t4.ics", "/t5.ics"] if current is None else current

    def events(joined):
        # The two event queries differ only in the window's end stamp: tonight's local
        # midnight vs the one seven days on. Naming them here doubles as an assertion —
        # a fetcher that built UTC windows would match neither and KeyError out.
        return multistatus(week if 'end="20260825T220000Z"' in joined else today)

    return FakeRun([
        ("propfind", CALDAV_HOME_XML),
        ("NEEDS-ACTION", multistatus(pending)),
        ('prop-filter name="DUE"', multistatus(due)),
        ('prop-filter name="DTSTART"', multistatus(dtstart)),
        # Before the bare "time-range" needle: the event bodies carry a time-range too,
        # and only the VTODO one should be answered with the href set.
        ("VEVENT", events),
        ("time-range", multistatus(current)),
    ])


# A Wednesday 20:30 at UTC+2 — the hour that makes a UTC-midnight window wrong.
CEST = datetime.timezone(datetime.timedelta(hours=2))
NOW = datetime.datetime(2026, 8, 19, 20, 30, tzinfo=CEST)


def test_calino_counts_events_and_tasks_due_now(tmp_path):
    # Of the five fixture todos only t1 and t2 are pending, dated and arrived.
    cfg = calino_cfg(tmp_path)
    run = calino_run(today=2, week=9)
    assert hs.fetch_calino(cfg, run, now=NOW) == {
        "today": 2, "week": 9, "tasks": 2}


def test_calino_windows_are_local_days_not_utc(tmp_path):
    # 20:30 CEST is 18:30 UTC, so a naive utcnow()-based window would start at
    # 20260819T000000Z — two hours late, dropping every event between local midnight
    # and 02:00 and pulling in tomorrow's.
    cfg = calino_cfg(tmp_path)
    run = calino_run()
    hs.fetch_calino(cfg, run, now=NOW)

    windows = [c for c in run.commands if "VEVENT" in c]
    assert len(windows) == 2
    assert all('start="20260818T220000Z"' in c for c in windows)
    # Local midnight tonight, and local midnight seven days on.
    assert any('end="20260819T220000Z"' in c for c in windows)
    assert any('end="20260825T220000Z"' in c for c in windows)


def test_calino_never_reads_firstoccurence_from_postgres(tmp_path):
    # The trap: oc_calendarobjects.firstoccurence/lastoccurence bound the whole
    # recurrence set, so a weekly event running for years matches "today" every day of
    # those years. The count must come from a server-side time-range instead.
    cfg = calino_cfg(tmp_path)
    run = calino_run()
    hs.fetch_calino(cfg, run, now=NOW)
    assert not any("PSQL" in c or "firstoccurence" in c for c in run.commands)
    assert all("time-range" in c for c in run.commands if "VEVENT" in c)


def test_calino_asks_each_calendar_only_for_what_it_holds(tmp_path):
    # 6 of the 11 real calendars are iCloud task lists. A VTODO-only list must never
    # be asked for events, nor an event calendar for tasks.
    cfg = calino_cfg(tmp_path)
    run = calino_run()
    hs.fetch_calino(cfg, run, now=NOW)

    for cmd in run.commands:
        if "VEVENT" in cmd:
            assert "calendars/nsimon/personal/" in cmd
        if "VTODO" in cmd:
            assert "calendars/nsimon/reminders/" in cmd
    # Rebuilt from nextcloud_dav_url, NOT joined from the /nextcloud hrefs.
    assert not any("/nextcloud/remote.php" in c for c in run.commands)
    assert all("http://nc/remote.php/dav/" in c for c in run.commands)


def test_calino_skips_collections_that_are_not_calendars(tmp_path):
    # inbox/outbox/trashbin answer the same PROPFIND; querying them 404s or 403s.
    cfg = calino_cfg(tmp_path)
    run = calino_run()
    hs.fetch_calino(cfg, run, now=NOW)
    assert not any("/inbox/" in c for c in run.commands)


def test_calino_does_not_count_its_own_settings_calendar(tmp_path):
    # Calino syncs its settings AS a VEVENT in `calino-settings`, a calendar that is
    # indistinguishable from a diary over CalDAV — it advertises VEVENT and holds
    # exactly one object. Counting it reported "1 event today" on an empty day.
    cfg = calino_cfg(tmp_path)
    run = calino_run()
    hs.fetch_calino(cfg, run, now=NOW)
    assert not any("calino-settings" in c for c in run.commands)


def test_calino_skips_webcal_subscriptions(tmp_path):
    # `{calendarserver}subscribed` collections (TRUSK, Google, Airbnb here) advertise
    # VEVENT and answer 207, but Nextcloud never exposes a subscription's contents over
    # DAV — every query returns zero objects, so they can only cost requests.
    cfg = calino_cfg(tmp_path)
    run = calino_run()
    hs.fetch_calino(cfg, run, now=NOW)
    assert not any("calendargooglecom" in c for c in run.commands)


def test_calino_excludes_undated_tasks(tmp_path):
    # t4 is pending and matches the time-range — undated VTODOs overlap EVERY range per
    # RFC 4791 §9.9 — but it carries neither DUE nor DTSTART, so it is not due "now" and
    # must not count. This is the whole reason the date test cannot be the time-range.
    # Live, this is what separates 5 from 55: the five shopping/gift lists are undated.
    cfg = calino_cfg(tmp_path)
    run = calino_run()
    assert hs.fetch_calino(cfg, run, now=NOW)["tasks"] == 2

    # An account of nothing but undated items must report zero, not "all of them".
    undated = calino_run(due=[], dtstart=[],
                         pending=["/a.ics", "/b.ics", "/c.ics"],
                         current=["/a.ics", "/b.ics", "/c.ics"])
    assert hs.fetch_calino(cfg, undated, now=NOW)["tasks"] == 0


def test_calino_excludes_future_dated_tasks(tmp_path):
    # t3 is pending with a DUE date, but outside (epoch, now] — 21 of the 27 pending in
    # `Reminders` are like this. A tile that counts them is not actionable.
    cfg = calino_cfg(tmp_path)
    run = calino_run()
    hs.fetch_calino(cfg, run, now=NOW)
    ranges = [c for c in run.commands if "time-range" in c and "VTODO" in c]
    assert ranges, "the future filter must be a server-side time-range"
    assert all('end="20260819T183000Z"' in c for c in ranges)  # 20:30 CEST == 18:30 UTC


def test_calino_counts_only_pending_tasks(tmp_path):
    # t5 is dated and arrived but COMPLETED. Filtered by STATUS server-side.
    cfg = calino_cfg(tmp_path)
    run = calino_run()
    hs.fetch_calino(cfg, run, now=NOW)
    assert any("NEEDS-ACTION" in c for c in run.commands)
    assert not any("COMPLETED" in c for c in run.commands)


def test_calino_does_not_ask_the_server_to_and_a_propfilter_with_a_time_range(tmp_path):
    # THE bug this guards. SabreDAV drops the prop-filter when a time-range shares the
    # comp-filter, and answers the range alone: `Reminders` returned 792 (every
    # completed task in range) for a query meant to yield 27. So no VTODO query may
    # carry both, and the AND has to be the href intersection.
    cfg = calino_cfg(tmp_path)
    run = calino_run()
    hs.fetch_calino(cfg, run, now=NOW)
    for cmd in run.commands:
        if "VTODO" in cmd and "time-range" in cmd:
            assert "prop-filter" not in cmd


def test_calino_skips_the_date_queries_when_nothing_is_pending(tmp_path):
    # Short-circuit: an all-done list costs one request, not four.
    cfg = calino_cfg(tmp_path)
    run = calino_run(pending=[])
    assert hs.fetch_calino(cfg, run, now=NOW)["tasks"] == 0
    assert not any("time-range" in c and "VTODO" in c for c in run.commands)
    assert not any("prop-filter" in c and "DUE" in c for c in run.commands)


def test_calino_skips_the_time_range_when_nothing_is_dated(tmp_path):
    # Five of the six live lists are entirely undated, so this is the common path.
    cfg = calino_cfg(tmp_path)
    run = calino_run(due=[], dtstart=[])
    assert hs.fetch_calino(cfg, run, now=NOW)["tasks"] == 0
    assert not any("time-range" in c and "VTODO" in c for c in run.commands)


def test_calino_reuses_the_nextcloud_app_password(tmp_path):
    # No second secret: serverinfo consumes this value as an NC-Token, but it is a real
    # app password, so it authenticates DAV too.
    cfg = calino_cfg(tmp_path)
    run = calino_run()
    hs.fetch_calino(cfg, run, now=NOW)
    assert all("nsimon:app-pw" in c for c in run.commands)


def ha_cfg(tmp_path):
    env_file = tmp_path / "env"
    env_file.write_text("HOMEPAGE_VAR_HA_TOKEN=t\n")
    return hs.Config(curl="CURL", sqlite="SQLITE", env_file=str(env_file),
                     hass_url="http://ha", hass_db="/db/hass")


HA_STATES = json.dumps([
    # Voltalis: a running daily counter per room, plus the heater's own switch.
    {"entity_id": "sensor.bathroom_sdb_daily_consumption", "state": "820"},
    {"entity_id": "sensor.kitchen_cuisine_daily_consumption", "state": "480"},
    {"entity_id": "switch.living_room_salon_device_switch", "state": "on"},
    {"entity_id": "switch.bedroom_chambre_device_switch", "state": "off"},
    # Not a heater switch — must not be counted as a room.
    {"entity_id": "switch.quicksettings_athome", "state": "on"},
])


def ha_run(day="3073|3895.43", cost="16.96|0.6523|0.91125", states=HA_STATES):
    # The two statistics queries differ only by the unit they filter on.
    return FakeRun([("'Wh'", day), ("'€'", cost), ("api/states", states)])


def test_home_assistant_reports_energy_against_a_baseline(tmp_path):
    # 3073 Wh against a 3895 Wh weekly mean is -21%; 0.6523 EUR/day against
    # 0.91125 is -28%. The euro figure shown is the 30-day TOTAL, but the delta
    # beside it compares daily means — see pct_delta.
    assert hs.fetch_homeassistant(ha_cfg(tmp_path), ha_run()) == {
        "day": "3.1 kWh (-21%)",
        "cost": "€16.96 (-28%)",
        "heating": "1.3 kWh (1 on)",
    }


def test_home_assistant_reads_the_recorder_database_read_only(tmp_path):
    # Without -readonly, sqlite3 creates root-owned -wal/-shm files next to a
    # database that hass (not root) has open for writing.
    run = ha_run()
    hs.fetch_homeassistant(ha_cfg(tmp_path), run)
    sqlite_calls = [c for c in run.commands if c.startswith("SQLITE")]
    assert len(sqlite_calls) == 2
    assert all("-readonly /db/hass" in c for c in sqlite_calls)


def test_home_assistant_survives_voltalis_reporting_nothing(tmp_path):
    # Every daily counter is "unknown" for a while after an HA restart, and
    # "unavailable" between polls. Neither is a number; neither may raise.
    states = json.dumps([
        {"entity_id": "sensor.bathroom_sdb_daily_consumption", "state": "unknown"},
        {"entity_id": "sensor.kitchen_cuisine_daily_consumption", "state": "unavailable"},
        {"entity_id": "sensor.bedroom_chambre_daily_consumption", "state": None},
    ])
    out = hs.fetch_homeassistant(ha_cfg(tmp_path), ha_run(states=states))
    assert out["heating"] == "0 Wh (0 on)"


def test_home_assistant_admits_when_there_is_nothing_to_compare_against(tmp_path):
    # A fresh ha-linky backfill has no prior week and no prior month. "+100%"
    # against a zero baseline would read as a real measurement.
    out = hs.fetch_homeassistant(ha_cfg(tmp_path), ha_run(day="900|0", cost="4.2|0.6|0"))
    assert out["day"] == "900 Wh (—)"
    assert out["cost"] == "€4.20 (—)"


def test_home_assistant_tolerates_an_empty_statistics_table(tmp_path):
    # sqlite3 prints nothing at all for a query over no rows in some shapes;
    # the COALESCEs should prevent it, but the parse must not depend on that.
    out = hs.fetch_homeassistant(ha_cfg(tmp_path), ha_run(day="", cost=""))
    assert out["day"] == "0 Wh (—)"


@pytest.mark.parametrize("wh,expected", [
    (0, "0 Wh"), (5, "5 Wh"), (999, "999 Wh"),
    (1000, "1.0 kWh"), (12400, "12.4 kWh"),
])
def test_watt_hours_switches_unit_at_a_kilowatt_hour(wh, expected):
    assert hs.watt_hours(wh) == expected


def recorder_db(path):
    """A recorder database with 40 complete days of hourly ha-linky statistics.

    Only the columns the two queries touch — this stands in for sqlite3(1), not
    for Home Assistant's schema, which has many more.

    Hours are built from LOCAL naive datetimes so they land in the local day the
    queries group by. A spring-forward day yields 23 of them rather than 24,
    which is exactly why the queries say `HAVING COUNT(*) >= 23`.
    """
    import sqlite3

    con = sqlite3.connect(path)
    con.executescript("""
        CREATE TABLE statistics_meta (
            id INTEGER PRIMARY KEY, statistic_id TEXT, unit_of_measurement TEXT);
        CREATE TABLE statistics (
            metadata_id INTEGER, start_ts REAL, state REAL, sum REAL);
        INSERT INTO statistics_meta VALUES
            (1, 'linky:1234', 'Wh'), (2, 'linky:1234_cost', '€');
    """)
    today = datetime.date.today()
    rows = []
    for ago in range(2, 42):
        day = today - datetime.timedelta(days=ago)
        # Newest complete day is a quiet one; the seven before it are twice that.
        wh = 100 if ago == 2 else 200
        # Halves at the 30-day boundary, so the rolling comparison is -50%.
        eur = 0.01 if ago < 30 else 0.02
        for hour in range(24):
            ts = datetime.datetime.combine(
                day, datetime.time(hour)).timestamp()
            rows.append((1, ts, wh, 0))
            rows.append((2, ts, eur, 0))
    con.executemany("INSERT INTO statistics VALUES (?,?,?,?)", rows)
    con.commit()
    con.close()


def real_sql_run(db_path, states=HA_STATES):
    """A `run` that executes the fetcher's SQL for real, in SQLite.

    FakeRun matches a query by substring and never parses it, so a malformed one
    passes every mocked test and fails only on the machine — which is how
    LINKY_COST_SQL shipped a CTE whose SELECT had no FROM clause.
    """
    import sqlite3

    def run(argv, env=None):
        if "api/states" in " ".join(argv):
            return states
        with sqlite3.connect(db_path) as con:
            return str(con.execute(argv[-1]).fetchone()[0])

    return run


def test_the_home_assistant_queries_are_valid_sql_over_a_real_table(tmp_path):
    db = tmp_path / "hass.db"
    recorder_db(db)
    out = hs.fetch_homeassistant(ha_cfg(tmp_path), real_sql_run(db))
    # 2400 Wh against a 4800 Wh weekly mean; 28 reported days at €0.24 against a
    # prior window at €0.48/day. Both halves come out of SQLite, not a fixture.
    assert out["day"] == "2.4 kWh (-50%)"
    assert out["cost"] == "€6.72 (-50%)"


def test_the_home_assistant_queries_ignore_incomplete_days(tmp_path):
    # Today and yesterday are always partial — Enedis publishes ~2 days behind —
    # so a half-reported day must never become "consumption halved".
    db = tmp_path / "hass.db"
    recorder_db(db)
    import sqlite3
    con = sqlite3.connect(db)
    today = datetime.date.today()
    for hour in range(3):
        ts = datetime.datetime.combine(today, datetime.time(hour)).timestamp()
        con.execute("INSERT INTO statistics VALUES (1,?,5,0)", (ts,))
    con.commit()
    con.close()
    # Unchanged: the three-hour stub is not a day.
    assert hs.fetch_homeassistant(ha_cfg(tmp_path), real_sql_run(db))["day"] \
        == "2.4 kWh (-50%)"


def test_reactive_resume_passes_its_password_through_the_environment(tmp_path):
    pw = tmp_path / "pw"
    pw.write_text("s3cret\n")
    cfg = hs.Config(psql="PSQL", rxresume_pw_file=str(pw))
    run = FakeRun([("PSQL", "4")])
    assert hs.fetch_reactive_resume(cfg, run) == {"resumes": 4, "users": 4, "views": 4}
    # In the env, never on the command line.
    for argv, env in run.calls:
        assert env["PGPASSWORD"] == "s3cret"
        assert "s3cret" not in " ".join(argv)


# ── env file ──────────────────────────────────────────────────────────────────


def test_a_secret_is_read_from_the_shared_env_file(tmp_path):
    env_file = tmp_path / "env"
    env_file.write_text("HOMEPAGE_VAR_SURE_KEY=abc123\nHOMEPAGE_VAR_HA_TOKEN=xyz\n")
    cfg = hs.Config(env_file=str(env_file))
    assert hs.env_var(cfg, "SURE_KEY") == "abc123"
    with pytest.raises(KeyError):
        hs.env_var(cfg, "NOPE")


# ── routing ───────────────────────────────────────────────────────────────────


def test_every_tile_has_its_own_endpoint_and_the_root_serves_everything():
    # Routing off the stats object means adding a widget touches one place.
    stats = hs.Stats()
    stats.set("papra", {"documents": 384})
    assert "papra" in stats
    assert "nope" not in stats
    assert stats.get("papra") == {"documents": 384}
    assert set(stats.snapshot()) == set(hs.Stats.KEYS)


def test_deleted_accounts_are_excluded_from_the_valuation_sums(tmp_path):
    """Deleting an account in Wealthfolio does NOT cascade to
    daily_account_valuation — 19 removed accounts left 6163 rows behind, worth
    EUR 23,626 of phantom investment value on every historical date. A bare
    sum read 57,850 where the truth was 34,224."""
    run = wealthfolio_run(json.dumps({"returns": {"valueReturn": 0.01}}))
    hs.fetch_wealthfolio(wealthfolio_cfg(tmp_path), run)
    query = next(c for c in run.commands if "cost_basis_base" in c)
    assert query.count("EXISTS (SELECT 1 FROM accounts") >= 2


def test_an_overspent_food_envelope_reads_negative():
    cfg = hs.Config(psql="PSQL", runuser="RUNUSER")
    run = FakeRun([("WITH food AS", "300.00|412.40"),
                   ("accountable_type = 'Depository'", "6640.47|240.47"),
                   ("e.amount > 0", "1928.56"),
                   ("FROM budgets", "2500.0000")])
    assert hs.fetch_sure(cfg, run)["food"] == "€412 (-112€)"


def test_a_key_holding_only_an_error_counts_as_missing():
    """An errored tile used to freeze for 24h: the error dict is truthy, so
    backfill skipped it and the daily tick was the next attempt."""
    stats = hs.Stats()
    stats.error("wealthfolio", "connection refused")
    assert "wealthfolio" in stats.missing()


def test_an_error_beside_good_values_does_not_count_as_missing():
    """The last-good-values behaviour must survive — a tile with data and a
    stale error still renders its data, and refetching it every loop would
    hammer a service that is merely flaky."""
    stats = hs.Stats()
    stats.set("wealthfolio", {"net_worth": "€1"})
    stats.error("wealthfolio", "transient")
    assert "wealthfolio" not in stats.missing()


def test_a_key_still_empty_after_backfill_is_retried_not_left_for_a_day(tmp_path):
    """The recurring case: a rebuild restarts homepage-stats and the service it
    reads together, the fetch loses the race, and the tile shows an error for
    24h. The loser of that race is up seconds later."""
    stats = hs.Stats()
    for key in hs.Stats.KEYS:
        stats.set(key, {"ok": 1})
    stats.error("wealthfolio", "connection refused")
    stats._data["wealthfolio"] = {"error": "connection refused"}

    attempts, slept = [], []
    def fake_fetcher(cfg, run, stats_, key, log=None):
        attempts.append(key)
        if len(attempts) == 1:                  # loses the race, as on a rebuild
            stats_.error(key, "connection refused")
            return False
        stats_.set(key, {"net_worth": "€1"})    # up seconds later
        return True

    orig = hs.run_fetcher
    hs.run_fetcher = fake_fetcher
    try:
        hs.refresh(hs.Config(state_dir=str(tmp_path)), None, stats, time.time(),
                   sleep=slept.append, once=True, log=lambda m: None)
    finally:
        hs.run_fetcher = orig
    assert "wealthfolio" in attempts
    assert hs.RETRY_INTERVAL in slept
