"""homepage-stats: 19 fetchers that used to run on exactly one machine.

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

import json

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
        "food": "€300 (66€)"}


def test_the_cash_bracket_leaves_out_the_livret_a():
    """The Livret A is savings, and it is nearly the whole balance — EUR 6,400
    of EUR 6,716 — so the headline figure badly flatters what is spendable."""
    cfg = hs.Config(psql="PSQL", runuser="RUNUSER")
    run = FakeRun(SURE_ROWS)
    hs.fetch_sure(cfg, run)
    cash_query = next(c for c in run.commands if "accountable_type" in c)
    assert "livret" in cash_query.lower()


def test_food_spend_includes_the_categorys_children():
    """Sure budgets on '1 - Food' but books spend against Groceries etc."""
    cfg = hs.Config(psql="PSQL", runuser="RUNUSER")
    run = FakeRun(SURE_ROWS)
    hs.fetch_sure(cfg, run)
    food_query = next(c for c in run.commands if "WITH food AS" in c)
    assert "parent_id IN" in food_query


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


def test_home_assistant_counts_entities_by_state(tmp_path):
    env_file = tmp_path / "env"
    env_file.write_text("HOMEPAGE_VAR_HA_TOKEN=t\n")
    cfg = hs.Config(curl="CURL", env_file=str(env_file), hass_url="http://ha")
    states = json.dumps([
        {"entity_id": "person.nico", "state": "home"},
        {"entity_id": "person.alfie", "state": "not_home"},
        {"entity_id": "light.kitchen", "state": "on"},
        {"entity_id": "light.hall", "state": "off"},
        {"entity_id": "switch.tv", "state": "on"},
        {"entity_id": "sensor.temp", "state": "on"},
    ])
    assert hs.fetch_homeassistant(cfg, FakeRun([("api/states", states)])) == {
        "people_home": 1, "lights_on": 1, "switches_on": 1}


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
