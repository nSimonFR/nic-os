"""steam-to-ryot: the playtime-delta logic and the Ryot V2 calls it makes.

These are the properties that keep the connector from double-counting playtime or
losing it across a failed run — otherwise only observable in production.
"""

import json
import urllib.error

from conftest import FakeOpener, json_reply

from nicos_scripts.connectors import steam

NOW = "2026-08-06T12:00:00.000Z"

ENV = {
    "STEAM_API_KEY": "k",
    "STEAM_ID64": "76561198000000000",
    "TWITCH_CLIENT_ID": "tc",
    "TWITCH_CLIENT_SECRET": "ts",
    "RYOT_API_KEY": "rk",
    "RYOT_URL": "http://ryot",
}

SAVED = json_reply({"result": {"count": 1, "status": "saved"}})


def game(appid, name, minutes, last_played=None):
    g = {"appid": appid, "name": name, "playtime_forever": minutes}
    if last_played:
        g["rtime_last_played"] = last_played
    return g


QUIT = 1761659640  # 2025-10-28T13:54:00Z


def no_sleep(_):
    pass


def paths(op):
    return [r.full_url.split("?")[0] for r in op.requests]


# ── Config ────────────────────────────────────────────────────────────────────


def test_config_reads_state_dir_and_derives_file_paths():
    cfg = steam.Config.from_env({**ENV, "STATE_DIR": "/tmp/x"})
    assert cfg.state_file == "/tmp/x/steam-state.json"
    assert cfg.igdb_map_file == "/tmp/x/steam-igdb-map.json"
    assert cfg.entity_map_file == "/tmp/x/steam-ryot-entities.json"
    assert cfg.min_delta_min == 1


def test_config_defaults():
    cfg = steam.Config.from_env({"RYOT_API_KEY": "rk"})
    assert cfg.state_dir == "/var/lib/ryot-connectors"
    assert cfg.ryot_url == "http://127.0.0.1:13350"


# ── playtime_deltas ───────────────────────────────────────────────────────────


def test_first_run_logs_the_whole_playtime():
    plays = steam.playtime_deltas([game(1, "Portal", 120)], {"1": "77"}, {}, now=NOW)
    assert plays == [
        {
            "appid": "1",
            "igdb_id": "77",
            "name": "Portal",
            "total": 120,
            "delta": 120,
            "submitted_at": NOW,
            "played_at": "",
            "untimed": False,
        }
    ]


def test_a_play_occurs_when_the_game_was_quit():
    (play,) = steam.playtime_deltas(
        [game(1, "Stardew", 150, QUIT)], {"1": "77"}, {"1": 101}, now=NOW
    )
    assert play["played_at"] == "2025-10-28T13:54:00.000Z" and play["delta"] == 49
    assert steam.activity_payload("e", play)["entry"]["when"] == {
        "kind": "date",
        "finishedOn": "2025-10-28T13:54:00.000Z",
    }


def test_no_new_playtime_logs_nothing():
    assert (
        steam.playtime_deltas([game(1, "Portal", 120)], {"1": "77"}, {"1": 120}) == []
    )


def test_only_the_delta_is_logged_never_the_cumulative_total():
    # Steam exposes cumulative playtime only; logging the total would double-count.
    (play,) = steam.playtime_deltas([game(1, "Portal", 150)], {"1": "77"}, {"1": 120})
    assert play["delta"] == 30 and play["total"] == 150


def test_growth_below_min_delta_is_ignored_and_accumulates():
    assert steam.playtime_deltas([game(1, "P", 124)], {"1": "77"}, {"1": 120}, 5) == []


def test_the_game_being_played_waits_for_its_session_to_end():
    games = [game(1, "Portal", 150), game(2, "Hades", 90)]
    plays = steam.playtime_deltas(
        games, {"1": "77", "2": "78"}, {}, playing="1", timed={"2"}
    )
    assert [(p["appid"], p["untimed"]) for p in plays] == [("2", False)]


def test_growth_without_a_seen_session_is_untimed():
    (play,) = steam.playtime_deltas(
        [game(1, "Portal", 150, QUIT)], {"1": "77"}, {"1": 100}, timed=set()
    )
    assert play["untimed"]
    assert (
        steam.activity_payload("e", play)["entry"]["consumedOn"] == "Steam (non daté)"
    )


def test_an_old_inflight_play_becomes_pending_unchanged():
    state = {"games": {"1": 40}, "inflight": {"1": {"total": 60, "submittedAt": "t0"}}}
    steam.migrate_inflight(state, {"1": "71"})
    (play,) = state["pending"]
    assert state["games"] == {"1": 60} and "inflight" not in state
    assert (play["total"], play["delta"], play["submitted_at"]) == (60, 20, "t0")
    assert steam.activity_payload("e", play)["entry"]["when"] == {"kind": "now"}


# ── sessions ──────────────────────────────────────────────────────────────────


def test_a_session_starts_continues_and_ends():
    state = {}
    steam.track_session(state, "1", 100)
    steam.track_session(state, "1", 400)
    assert state["session"] == {"appid": "1", "start": 100, "seen": 400}
    steam.track_session(state, "", 700)
    assert "session" not in state
    assert state["ended"] == [{"appid": "1", "start": 100, "end": 400}]


def test_switching_games_ends_the_first_session():
    state = {}
    steam.track_session(state, "1", 100)
    steam.track_session(state, "2", 400)
    assert state["ended"][0]["appid"] == "1" and state["session"]["appid"] == "2"


def test_unknown_presence_changes_nothing():
    state = {"session": {"appid": "1", "start": 100, "seen": 100}}
    steam.track_session(state, None, 400)
    assert state == {"session": {"appid": "1", "start": 100, "seen": 100}}


def test_unmapped_unknown_and_unplayed_games_are_skipped():
    games = [game(1, "Portal", 60), game(2, "Unmapped", 60), game(3, "Absent", 60)]
    games.append(game(4, "Never Launched", 0))
    plays = steam.playtime_deltas(games, {"1": "77", "2": "", "4": "88"}, {})
    assert [p["appid"] for p in plays] == ["1"]


# ── payload ───────────────────────────────────────────────────────────────────


def test_activity_payload_matches_the_migrated_v1_shape():
    play = {"appid": "1", "total": 150, "delta": 30, "submitted_at": NOW}
    payload = steam.activity_payload("met_x", play)
    assert payload["entry"] == {
        "kind": "complete",
        "entityId": "met_x",
        "when": {"kind": "now"},
        "timeSpent": 30,  # minutes, as V1 seconds / 60
        "consumedOn": "Steam",
    }
    assert payload["submittedAt"] == NOW


def test_submission_id_is_keyed_on_appid_and_new_total():
    play = {"appid": "1", "total": 150, "delta": 30, "submitted_at": NOW}
    assert steam.activity_payload("e", play)["submissionId"] == "steam-1-150"


# ── IGDB resolution ───────────────────────────────────────────────────────────


def test_resolve_igdb_ids_caches_hits_and_misses():
    cfg = steam.Config.from_env(ENV)
    op = FakeOpener([json_reply([{"uid": "1", "game": 77}])])
    igdb_map = {}
    steam.resolve_igdb_ids([1, 2], "tok", igdb_map, cfg, opener=op, sleep=no_sleep)
    # "" for the miss so we never re-query it; IGDB is rate-limited.
    assert igdb_map == {"1": "77", "2": ""}
    assert op.last.get_header("Client-id") == "tc"
    assert b"external_game_source = 1" in op.last.data


def test_resolve_igdb_ids_skips_appids_already_cached():
    cfg = steam.Config.from_env(ENV)
    op = FakeOpener([json_reply([])])
    steam.resolve_igdb_ids([1], "tok", {"1": ""}, cfg, opener=op, sleep=no_sleep)
    assert op.requests == []


def test_resolve_igdb_ids_survives_an_http_error():
    cfg = steam.Config.from_env(ENV)

    def boom(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, 429, "slow down", {}, None)

    igdb_map = {}
    steam.resolve_igdb_ids([1], "tok", igdb_map, cfg, opener=boom, sleep=no_sleep)
    # Left unresolved rather than cached as a miss — a 429 is not "no such game".
    assert igdb_map == {}


# ── Ryot client ───────────────────────────────────────────────────────────────


def ryot_client(replies, sleeps=None):
    op = FakeOpener(replies)
    sleep = sleeps.append if sleeps is not None else no_sleep
    return steam.RyotClient(steam.Config.from_env(ENV), opener=op, sleep=sleep), op


def test_client_paces_every_call_after_the_first():
    sleeps = []
    client, op = ryot_client([json_reply({"data": {}})], sleeps)
    for _ in range(3):
        client.query({})
    assert sleeps == [steam.RYOT_PAUSE_SEC] * 2
    assert op.last.get_header("X-api-key") == "rk"


def test_client_backs_off_and_retries_on_429():
    sleeps = []

    def limited():
        raise urllib.error.HTTPError("u", 429, "too many", {}, None)

    client, op = ryot_client([limited, json_reply({"data": {"ok": 1}})], sleeps)
    assert client.query({}) == {"ok": 1}
    assert steam.RATE_LIMIT_BACKOFF_SEC in sleeps
    assert len(op.requests) == 2


def test_find_games_filters_on_the_igdb_provider_and_external_ids():
    client, op = ryot_client(
        [json_reply({"data": {"g": {"items": [{"id": "met_a", "externalId": "77"}]}}})]
    )
    assert client.find_games("prov", ["77", "88"]) == {"77": "met_a"}
    where = op.body_of()["queries"]["g"]["where"]["predicates"]
    assert where[1]["right"]["value"] == "prov"
    assert [v["value"] for v in where[2]["values"]] == ["77", "88"]


def test_import_game_polls_until_completed():
    client, op = ryot_client(
        [
            json_reply({"jobId": "j/1"}),
            json_reply({"status": "running"}),
            json_reply({"status": "completed", "data": {"id": "met_new"}}),
        ]
    )
    assert client.import_game("prov", "77") == "met_new"
    assert op.body_of(0) == {"providerId": "prov", "externalId": "77"}
    assert op.last.full_url.endswith("/api/entity-providers/imports/j%2F1")


def test_import_game_reports_a_failed_import_as_empty():
    client, _ = ryot_client(
        [json_reply({"jobId": "j"}), json_reply({"status": "failed"})]
    )
    assert client.import_game("prov", "77") == ""


def test_log_play_raises_when_the_operation_refuses():
    client, _ = ryot_client([json_reply({"result": {"kind": "invalid", "code": "x"}})])
    play = {"appid": "1", "total": 60, "delta": 60, "submitted_at": NOW}
    try:
        client.log_play("met_a", play)
    except RuntimeError as e:
        assert "did not save" in str(e)
    else:
        raise AssertionError("a refused operation must not count as saved")


# ── main ──────────────────────────────────────────────────────────────────────


def test_main_fails_fast_on_missing_env(capsys):
    assert steam.main(env={}) == 1
    assert "missing env" in capsys.readouterr().out


def test_main_skips_cleanly_without_twitch_creds(capsys):
    env = {**ENV, "TWITCH_CLIENT_ID": "", "TWITCH_CLIENT_SECRET": ""}
    # Installed-but-dormant must not fail the timer unit.
    assert steam.main(env=env) == 0
    assert "skipping" in capsys.readouterr().out


T = 1786017600  # NOW as epoch


def presence(gameid=""):
    player = {"steamid": "x"}
    if gameid:
        player["gameid"] = gameid
    return json_reply({"response": {"players": [player]}})


def owned(*games):
    return json_reply({"response": {"games": list(games)}})


def steam_replies(*games):
    # main() calls out in this order: presence, owned games, Twitch, IGDB.
    return [
        presence(),
        owned(*games),
        json_reply({"access_token": "tok"}),
        json_reply([{"uid": str(g["appid"]), "game": 70 + g["appid"]} for g in games]),
    ]


def run(tmp_path, replies, t=T, **kw):
    op = FakeOpener(replies)
    env = {**ENV, "STATE_DIR": str(tmp_path)}
    rc = steam.main(env=env, opener=op, sleep=no_sleep, now=NOW, clock=lambda: t, **kw)
    return rc, op


def read(tmp_path, name):
    return json.loads((tmp_path / name).read_text())


def write(tmp_path, name, value):
    (tmp_path / name).write_text(json.dumps(value))


def cached(tmp_path, state):
    write(tmp_path, "steam-igdb-map.json", {"1": "71", "2": "72"})
    write(tmp_path, "steam-ryot-entities.json", {"1": "met_a", "2": "met_b"})
    write(tmp_path, "steam-state.json", state)


def test_main_end_to_end_resolves_logs_and_advances_state(tmp_path):
    rc, op = run(
        tmp_path,
        steam_replies(game(1, "Portal", 60))
        + [
            json_reply({"data": {"p": {"items": [{"id": "prov"}]}}}),
            json_reply(
                {"data": {"g": {"items": [{"id": "met_a", "externalId": "71"}]}}}
            ),
            SAVED,
        ],
    )
    assert rc == 0
    assert read(tmp_path, "steam-state.json") == {"games": {"1": 60}, "checked": T}
    assert read(tmp_path, "steam-igdb-map.json") == {"1": "71"}
    assert read(tmp_path, "steam-ryot-entities.json") == {"1": "met_a"}
    assert (
        paths(op)[-1]
        == "http://ryot/api/plugins/ryot/media/operations/media-activity-log"
    )
    payload = op.body_of()["payload"]
    assert payload["submissionId"] == "steam-1-60"
    assert payload["entry"]["timeSpent"] == 60


def test_main_imports_a_game_ryot_does_not_know(tmp_path):
    rc, op = run(
        tmp_path,
        steam_replies(game(1, "Portal", 60))
        + [
            json_reply({"data": {"p": {"items": [{"id": "prov"}]}}}),
            json_reply({"data": {"g": {"items": []}}}),
            json_reply({"jobId": "j"}),
            json_reply({"status": "completed", "data": {"id": "met_new"}}),
            SAVED,
        ],
    )
    assert rc == 0
    assert read(tmp_path, "steam-ryot-entities.json") == {"1": "met_new"}
    assert op.body_of()["payload"]["entry"]["entityId"] == "met_new"


def test_between_checks_a_run_only_reads_presence(tmp_path):
    cached(tmp_path, {"games": {"1": 60}, "checked": T - 600})
    rc, op = run(tmp_path, [presence("1")])
    assert rc == 0 and len(op.requests) == 1
    assert read(tmp_path, "steam-state.json")["session"] == {
        "appid": "1",
        "start": T,
        "seen": T,
    }


def test_an_ended_session_is_logged_as_one_timed_play(tmp_path):
    cached(
        tmp_path,
        {
            "games": {"1": 40},
            "checked": T - 600,
            "session": {"appid": "1", "start": T - 3600, "seen": T - 300},
        },
    )
    rc, op = run(tmp_path, [presence(), owned(game(1, "Portal", 95, QUIT)), SAVED])
    assert rc == 0
    entry = op.body_of()["payload"]["entry"]
    assert (entry["timeSpent"], entry["consumedOn"]) == (55, "Steam")
    assert read(tmp_path, "steam-state.json") == {"games": {"1": 95}, "checked": T}


def test_a_ryot_outage_queues_plays_and_never_merges_them(tmp_path):
    cached(tmp_path, {"games": {"1": 40}, "checked": T - 600})
    state = read(tmp_path, "steam-state.json")
    state["session"] = {"appid": "1", "start": T - 3600, "seen": T - 300}
    write(tmp_path, "steam-state.json", state)

    def down():
        raise urllib.error.HTTPError("u", 500, "boom", {}, None)

    rc, _ = run(tmp_path, [presence(), owned(game(1, "Portal", 60)), down])
    assert rc == 0  # young: retried quietly
    # Played again; Ryot is still down when that session ends too.
    state = read(tmp_path, "steam-state.json")
    state["session"] = {"appid": "1", "start": T, "seen": T + 1800}
    write(tmp_path, "steam-state.json", state)
    rc, _ = run(
        tmp_path, [presence(), owned(game(1, "Portal", 90)), down, down], t=T + 7200
    )
    assert rc == 1  # the first play is now stale
    pending = read(tmp_path, "steam-state.json")["pending"]
    assert [(p["delta"], p["total"]) for p in pending] == [(20, 60), (30, 90)]
    rc, op = run(tmp_path, [presence(), SAVED, SAVED], t=T + 7500)
    assert rc == 0
    assert [json.loads(r.data)["payload"]["submissionId"] for r in op.requests[1:]] == [
        "steam-1-60",
        "steam-1-90",
    ]
    assert "pending" not in read(tmp_path, "steam-state.json")


def test_the_periodic_check_logs_unseen_growth_as_untimed(tmp_path):
    cached(tmp_path, {"games": {"2": 10}, "checked": T - steam.CHECK_EVERY_S})
    rc, op = run(tmp_path, [presence(), owned(game(2, "Hades", 40, QUIT)), SAVED])
    assert rc == 0
    assert op.body_of()["payload"]["entry"]["consumedOn"] == "Steam (non daté)"


def test_an_ended_session_steam_never_counted_expires(tmp_path):
    cached(
        tmp_path,
        {
            "games": {"1": 60},
            "checked": T - 600,
            "ended": [
                {"appid": "1", "start": T - 9000, "end": T - steam.ENDED_GRACE_S}
            ],
        },
    )
    rc, _ = run(tmp_path, [presence(), owned(game(1, "Portal", 60))])
    assert rc == 0
    assert "ended" not in read(tmp_path, "steam-state.json")


def test_presence_down_still_runs_the_periodic_check(tmp_path):
    cached(tmp_path, {"games": {"1": 40}})

    def down():
        raise urllib.error.URLError("dns")

    rc, op = run(tmp_path, [down, owned(game(1, "Portal", 60)), SAVED])
    assert rc == 0 and op.body_of()["payload"]["entry"]["timeSpent"] == 20


def test_a_failed_import_is_not_cached_and_is_retried(tmp_path):
    rc, _ = run(
        tmp_path,
        steam_replies(game(1, "Portal", 60))
        + [
            json_reply({"data": {"p": {"items": [{"id": "prov"}]}}}),
            json_reply({"data": {"g": {"items": []}}}),
            json_reply({"jobId": "j"}),
            json_reply({"status": "failed"}),
        ],
    )
    assert rc == 0
    assert read(tmp_path, "steam-ryot-entities.json") == {}
    assert len(read(tmp_path, "steam-state.json")["pending"]) == 1


def test_main_with_no_new_playtime_makes_no_ryot_call(tmp_path):
    cached(tmp_path, {"games": {"1": 60}})
    rc, op = run(tmp_path, [presence(), owned(game(1, "Portal", 60))])
    assert rc == 0
    assert not any("ryot" in p for p in paths(op))
