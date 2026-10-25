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


def game(appid, name, minutes):
    return {"appid": appid, "name": name, "playtime_forever": minutes}


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
        }
    ]


def test_no_new_playtime_logs_nothing():
    assert steam.playtime_deltas([game(1, "Portal", 120)], {"1": "77"}, {"1": 120}) == []


def test_only_the_delta_is_logged_never_the_cumulative_total():
    # Steam exposes cumulative playtime only; logging the total would double-count.
    (play,) = steam.playtime_deltas([game(1, "Portal", 150)], {"1": "77"}, {"1": 120})
    assert play["delta"] == 30 and play["total"] == 150


def test_growth_below_min_delta_is_ignored_and_accumulates():
    assert steam.playtime_deltas([game(1, "P", 124)], {"1": "77"}, {"1": 120}, 5) == []


def test_an_inflight_play_is_resent_exactly_as_first_sent():
    # Steam has grown past it since; the extra 30 min wait for the next run.
    inflight = {"1": {"total": 150, "submittedAt": "earlier"}}
    (play,) = steam.playtime_deltas(
        [game(1, "Portal", 180)], {"1": "77"}, {"1": 120}, 1, inflight, NOW
    )
    assert (play["total"], play["delta"], play["submitted_at"]) == (150, 30, "earlier")


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
    client, _ = ryot_client([json_reply({"jobId": "j"}), json_reply({"status": "failed"})])
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


def steam_replies(*games):
    # main() calls out in this order: Steam, Twitch, IGDB.
    return [
        json_reply({"response": {"games": list(games)}}),
        json_reply({"access_token": "tok"}),
        json_reply([{"uid": str(g["appid"]), "game": 70 + g["appid"]} for g in games]),
    ]


def run(tmp_path, replies, **kw):
    op = FakeOpener(replies)
    env = {**ENV, "STATE_DIR": str(tmp_path)}
    return steam.main(env=env, opener=op, sleep=no_sleep, now=NOW, **kw), op


def read(tmp_path, name):
    return json.loads((tmp_path / name).read_text())


def test_main_end_to_end_resolves_logs_and_advances_state(tmp_path):
    rc, op = run(
        tmp_path,
        steam_replies(game(1, "Portal", 60))
        + [
            json_reply({"data": {"p": {"items": [{"id": "prov"}]}}}),
            json_reply({"data": {"g": {"items": [{"id": "met_a", "externalId": "71"}]}}}),
            SAVED,
        ],
    )
    assert rc == 0
    assert read(tmp_path, "steam-state.json") == {"games": {"1": 60}}
    assert read(tmp_path, "steam-igdb-map.json") == {"1": "71"}
    assert read(tmp_path, "steam-ryot-entities.json") == {"1": "met_a"}
    assert paths(op)[-1] == "http://ryot/api/plugins/ryot/media/operations/media-activity-log"
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


def test_main_uses_cached_entities_without_querying_ryot(tmp_path):
    (tmp_path / "steam-igdb-map.json").write_text('{"1": "71"}')
    (tmp_path / "steam-ryot-entities.json").write_text('{"1": "met_a"}')
    (tmp_path / "steam-state.json").write_text('{"games": {"1": 40}}')
    replies = [
        json_reply({"response": {"games": [game(1, "Portal", 60)]}}),
        json_reply({"access_token": "tok"}),
        SAVED,
    ]
    rc, op = run(tmp_path, replies)
    assert rc == 0
    assert len(op.requests) == 3
    assert op.body_of()["payload"]["entry"]["timeSpent"] == 20
    assert op.body_of()["payload"]["submissionId"] == "steam-1-60"


def test_a_failed_play_keeps_its_old_total_and_fails_the_run(tmp_path):
    (tmp_path / "steam-igdb-map.json").write_text('{"1": "71", "2": "72"}')
    (tmp_path / "steam-ryot-entities.json").write_text('{"1": "met_a", "2": "met_b"}')

    def down():
        raise urllib.error.HTTPError("u", 500, "boom", {}, None)

    replies = [
        json_reply({"response": {"games": [game(1, "A", 60), game(2, "B", 30)]}}),
        json_reply({"access_token": "tok"}),
        down,
        SAVED,
    ]
    rc, _ = run(tmp_path, replies)
    assert rc == 1
    # A stays inflight with its stamp, so the next run resends it unchanged; B advanced.
    assert read(tmp_path, "steam-state.json") == {
        "games": {"2": 30},
        "inflight": {"1": {"total": 60, "submittedAt": NOW}},
    }


def test_the_next_run_resends_the_inflight_play_unchanged(tmp_path):
    (tmp_path / "steam-igdb-map.json").write_text('{"1": "71"}')
    (tmp_path / "steam-ryot-entities.json").write_text('{"1": "met_a"}')
    (tmp_path / "steam-state.json").write_text(
        json.dumps({"games": {"1": 40}, "inflight": {"1": {"total": 60, "submittedAt": "t0"}}})
    )
    replies = [
        json_reply({"response": {"games": [game(1, "Portal", 90)]}}),
        json_reply({"access_token": "tok"}),
        SAVED,
    ]
    rc, op = run(tmp_path, replies)
    assert rc == 0
    payload = op.body_of()["payload"]
    assert payload["submittedAt"] == "t0" and payload["submissionId"] == "steam-1-60"
    assert payload["entry"]["timeSpent"] == 20
    # The inflight key is dropped once empty: the file keeps V1's shape.
    assert read(tmp_path, "steam-state.json") == {"games": {"1": 60}}


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
    assert rc == 1
    assert read(tmp_path, "steam-ryot-entities.json") == {}
    assert not (tmp_path / "steam-state.json").exists()


def test_main_with_no_new_playtime_makes_no_ryot_call(tmp_path):
    (tmp_path / "steam-igdb-map.json").write_text('{"1": "71"}')
    (tmp_path / "steam-state.json").write_text('{"games": {"1": 60}}')
    replies = [
        json_reply({"response": {"games": [game(1, "Portal", 60)]}}),
        json_reply({"access_token": "tok"}),
    ]
    rc, op = run(tmp_path, replies)
    assert rc == 0
    assert not any("ryot" in p for p in paths(op))
