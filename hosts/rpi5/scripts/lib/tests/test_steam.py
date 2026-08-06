"""steam-to-ryot: the playtime-delta and two-phase-completion logic.

These are the properties that keep the connector from double-counting playtime or
duplicating a game in Ryot's library — previously only observable in production.
"""

import json

from conftest import FakeOpener, json_reply

from nicos_scripts.connectors import steam

NOW = "2026-08-06T12:00:00+00:00"

ENV = {
    "STEAM_API_KEY": "k",
    "STEAM_ID64": "76561198000000000",
    "TWITCH_CLIENT_ID": "tc",
    "TWITCH_CLIENT_SECRET": "ts",
    "RYOT_WEBHOOK_URL": "http://ryot/_i/slug",
}


def game(appid, name, minutes):
    return {"appid": appid, "name": name, "playtime_forever": minutes}


# ── Config ────────────────────────────────────────────────────────────────────


def test_config_reads_state_dir_and_derives_file_paths():
    cfg = steam.Config.from_env({**ENV, "STATE_DIR": "/tmp/x"})
    assert cfg.state_file == "/tmp/x/steam-state.json"
    assert cfg.igdb_map_file == "/tmp/x/steam-igdb-map.json"
    assert cfg.min_delta_min == 1


def test_config_defaults_to_the_service_state_dir():
    assert steam.Config.from_env(ENV).state_dir == "/var/lib/ryot-connectors"


# ── build_payload ─────────────────────────────────────────────────────────────


def test_first_run_pushes_played_games_and_marks_them_pending():
    meta, new_games, pending = build([game(1, "Portal", 120)], {"1": "77"}, {})
    assert len(meta) == 1
    assert meta[0]["identifier"] == "77"
    assert meta[0]["source"] == "igdb"
    assert meta[0]["seen_history"][0]["manual_time_spent"] == "7200"  # 120 min
    assert new_games == {"1": 120}
    # First-ever games land as in_progress@0, so they must be re-pushed next run.
    assert pending == [
        {"identifier": "77", "source_id": "Portal", "seconds": "7200", "ended_on": NOW}
    ]


def test_second_run_with_no_new_playtime_pushes_nothing():
    meta, new_games, pending = build([game(1, "Portal", 120)], {"1": "77"}, {"1": 120})
    assert meta == []
    assert pending == []
    assert new_games == {"1": 120}


def test_only_the_delta_is_pushed_never_the_cumulative_total():
    # Steam exposes cumulative playtime only; pushing the total would double-count.
    meta, new_games, pending = build([game(1, "Portal", 150)], {"1": "77"}, {"1": 120})
    assert meta[0]["seen_history"][0]["manual_time_spent"] == "1800"  # 30 min
    assert new_games == {"1": 150}
    # A game we have pushed before completes immediately — it must not re-enter
    # pending, or its seen would be duplicated on every run.
    assert pending == []


def test_growth_below_min_delta_is_ignored():
    meta, new_games, _ = build(
        [game(1, "Portal", 124)], {"1": "77"}, {"1": 120}, min_delta_min=5
    )
    assert meta == []
    # State keeps the OLD value, so the small delta accumulates until it counts.
    assert new_games == {"1": 120}


def test_unmapped_and_unknown_appids_are_skipped():
    games = [game(1, "Portal", 60), game(2, "Unmapped", 60), game(3, "Absent", 60)]
    # "" marks a known-unmapped appid; 3 is not in the cache at all.
    meta, new_games, _ = build(games, {"1": "77", "2": ""}, {})
    assert [m["identifier"] for m in meta] == ["77"]
    assert new_games == {"1": 60}


def test_unplayed_games_never_persist():
    # No seen -> the Generic JSON sink cannot attach the game to the library.
    meta, _, _ = build([game(1, "Never Launched", 0)], {"1": "77"}, {})
    assert meta == []


def test_payload_item_carries_the_fields_ryot_requires():
    meta, _, _ = build([game(1, "Portal", 60)], {"1": "77"}, {})
    assert meta[0]["reviews"] == [] and meta[0]["collections"] == []
    assert meta[0]["lot"] == "video_game"
    assert meta[0]["seen_history"][0]["providers_consumed_on"] == ["Steam"]


def build(games, igdb_map, prev, min_delta_min=1):
    return steam.build_payload(games, igdb_map, prev, min_delta_min, now=NOW)


# ── IGDB resolution ───────────────────────────────────────────────────────────


def test_resolve_igdb_ids_caches_hits_and_misses():
    cfg = steam.Config.from_env(ENV)
    op = FakeOpener([json_reply([{"uid": "1", "game": 77}])])
    igdb_map = {}
    steam.resolve_igdb_ids([1, 2], "tok", igdb_map, cfg, opener=op, sleep=lambda _: None)
    # "" for the miss so we never re-query it; IGDB is rate-limited.
    assert igdb_map == {"1": "77", "2": ""}
    assert op.last.get_header("Client-id") == "tc"
    assert b'external_game_source = 1' in op.last.data


def test_resolve_igdb_ids_skips_appids_already_cached():
    cfg = steam.Config.from_env(ENV)
    op = FakeOpener([json_reply([])])
    steam.resolve_igdb_ids(
        [1], "tok", {"1": ""}, cfg, opener=op, sleep=lambda _: None
    )
    assert op.requests == []


def test_resolve_igdb_ids_survives_an_http_error():
    import urllib.error

    cfg = steam.Config.from_env(ENV)

    def boom(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, 429, "slow down", {}, None)

    igdb_map = {}
    steam.resolve_igdb_ids([1], "tok", igdb_map, cfg, opener=boom, sleep=lambda _: None)
    # Left unresolved rather than cached as a miss — a 429 is not "no such game".
    assert igdb_map == {}


# ── main ──────────────────────────────────────────────────────────────────────


def test_main_fails_fast_on_missing_env(capsys):
    assert steam.main(env={}) == 1
    assert "missing env" in capsys.readouterr().out


def test_main_skips_cleanly_without_twitch_creds(capsys):
    env = {**ENV, "TWITCH_CLIENT_ID": "", "TWITCH_CLIENT_SECRET": ""}
    # Installed-but-dormant must not fail the timer unit.
    assert steam.main(env=env) == 0
    assert "skipping" in capsys.readouterr().out


def test_main_end_to_end_writes_state_and_posts_once(tmp_path):
    # Reply queue in the order main() calls out: Steam, Twitch, IGDB, Ryot sink.
    op = FakeOpener(
        [
            json_reply({"response": {"games": [game(1, "Portal", 60)]}}),
            json_reply({"access_token": "tok"}),
            json_reply([{"uid": "1", "game": 77}]),
            json_reply({}, 200),
        ]
    )
    env = {**ENV, "STATE_DIR": str(tmp_path)}

    assert steam.main(env=env, opener=op) == 0

    state = json.loads((tmp_path / "steam-state.json").read_text())
    assert state == {
        "games": {"1": 60},
        "pending": [
            {
                "identifier": "77",
                "source_id": "Portal",
                "seconds": "3600",
                "ended_on": state["pending"][0]["ended_on"],
            }
        ],
    }
    assert json.loads((tmp_path / "steam-igdb-map.json").read_text()) == {"1": "77"}
    pushed = json.loads(op.requests[-1].data.decode())["metadata"]
    assert len(pushed) == 1


def test_main_reports_failure_when_ryot_rejects_the_push(tmp_path):
    op = FakeOpener(
        [
            json_reply({"response": {"games": [game(1, "Portal", 60)]}}),
            json_reply({"access_token": "tok"}),
            json_reply([{"uid": "1", "game": 77}]),
            json_reply({}, 500),
        ]
    )
    env = {**ENV, "STATE_DIR": str(tmp_path)}
    assert steam.main(env=env, opener=op) == 1
    # State must NOT advance on a failed push, or the playtime is lost forever.
    assert not (tmp_path / "steam-state.json").exists()
