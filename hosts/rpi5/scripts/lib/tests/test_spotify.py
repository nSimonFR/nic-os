"""spotify-to-ryot: per-listen dedupe and the two-phase completion."""

import json

from conftest import FakeOpener, json_reply

from nicos_scripts.connectors import spotify

ENV = {
    "SPOTIFY_CLIENT_ID": "cid",
    "SPOTIFY_CLIENT_SECRET": "csec",
    "SPOTIFY_REFRESH_TOKEN": "rtok",
    "RYOT_WEBHOOK_URL": "http://ryot/_i/slug",
}


def item(track_id, name, played_at):
    return {"played_at": played_at, "track": {"id": track_id, "name": name}}


def ms(iso):
    return spotify.iso_to_ms(iso)


def key(track_id, iso):
    return spotify.listen_key(track_id, ms(iso))


# ── iso_to_ms ─────────────────────────────────────────────────────────────────


def test_iso_to_ms_handles_the_trailing_z_and_millis():
    assert spotify.iso_to_ms("1970-01-01T00:00:01Z") == 1000
    assert spotify.iso_to_ms("1970-01-01T00:00:01.500Z") == 1500


def test_iso_to_ms_assumes_utc_when_no_offset_is_given():
    assert spotify.iso_to_ms("1970-01-01T00:00:01") == 1000


# ── listen keys ───────────────────────────────────────────────────────────────


def test_key_ms_round_trips_a_listen_key():
    assert spotify.key_ms(spotify.listen_key("t1", 1234)) == 1234


def test_key_ms_returns_none_for_a_malformed_key():
    assert spotify.key_ms("no-timestamp-here") is None


def test_prune_keys_drops_only_what_is_past_the_horizon():
    newest = ms("2026-08-06T10:00:00Z")
    fresh = spotify.listen_key("t1", newest - 1000)
    stale = spotify.listen_key("t2", newest - spotify.RETAIN_MS - 1000)
    assert spotify.prune_keys({fresh, stale}, newest) == [fresh]


def test_prune_keys_keeps_everything_when_there_is_no_high_water_mark():
    k = spotify.listen_key("t1", 5)
    assert spotify.prune_keys({k}, None) == [k]


def test_prune_keys_drops_malformed_keys():
    newest = ms("2026-08-06T10:00:00Z")
    assert spotify.prune_keys({"garbage"}, newest) == []


# ── build_payload ─────────────────────────────────────────────────────────────


def test_first_run_pushes_every_listen_and_records_the_high_water_mark():
    known, pushed = set(), set()
    meta, newest, pending = spotify.build_payload(
        [
            item("t1", "One", "2026-08-06T10:00:00Z"),
            item("t2", "Two", "2026-08-06T11:00:00Z"),
        ],
        known,
        pushed,
    )
    assert [m["identifier"] for m in meta] == ["t1", "t2"]
    assert newest == ms("2026-08-06T11:00:00Z")
    assert [p["identifier"] for p in pending] == ["t1", "t2"]
    assert known == {"t1", "t2"}
    assert pushed == {key("t1", "2026-08-06T10:00:00Z"), key("t2", "2026-08-06T11:00:00Z")}


def test_an_already_pushed_listen_is_not_pushed_again():
    pushed = {key("t1", "2026-08-06T10:00:00Z")}
    meta, _, _ = spotify.build_payload(
        [
            item("t1", "One", "2026-08-06T10:00:00Z"),
            item("t2", "Two", "2026-08-06T10:30:00Z"),
        ],
        set(),
        pushed,
    )
    assert [m["identifier"] for m in meta] == ["t2"]


def test_a_listen_that_syncs_late_from_an_offline_device_is_still_pushed():
    # The regression this dedupe exists for: a phone play carries its original
    # played_at, so it arrives *behind* the high-water mark. Anchoring on the
    # mark (as the old `after` cursor did) dropped it forever.
    prev_newest = ms("2026-08-06T12:00:00Z")
    meta, newest, _ = spotify.build_payload(
        [item("t1", "Offline", "2026-08-06T08:00:00Z")],
        set(),
        set(),
        prev_newest=prev_newest,
    )
    assert [m["identifier"] for m in meta] == ["t1"]
    assert newest == prev_newest  # a late arrival must not drag the mark backwards


def test_the_same_track_at_a_different_time_is_a_distinct_listen():
    pushed = {key("t1", "2026-08-06T10:00:00Z")}
    meta, _, _ = spotify.build_payload(
        [item("t1", "One", "2026-08-06T14:00:00Z")], {"t1"}, pushed
    )
    assert len(meta) == 1  # a repeat play, not a duplicate


def test_a_known_track_is_pushed_but_not_queued_for_completion():
    # Its metadata already exists in Ryot, so the seen completes immediately;
    # re-pushing it next run would duplicate the listen.
    meta, _, pending = spotify.build_payload(
        [item("t1", "One", "2026-08-06T10:00:00Z")], {"t1"}, set()
    )
    assert len(meta) == 1
    assert pending == []


def test_items_without_a_track_id_or_timestamp_are_skipped():
    meta, newest, _ = spotify.build_payload(
        [
            {"played_at": "2026-08-06T10:00:00Z", "track": {}},
            {"track": {"id": "t1", "name": "One"}},
            {"played_at": "2026-08-06T10:00:00Z"},
        ],
        set(),
        set(),
    )
    assert meta == []
    assert newest == 0


def test_high_water_mark_never_moves_backwards_on_an_empty_poll():
    prev = ms("2026-08-06T10:00:00Z")
    _, newest, _ = spotify.build_payload([], set(), set(), prev_newest=prev)
    assert newest == prev


def test_the_bootstrap_floor_suppresses_the_push_but_still_records_the_key():
    # Migration of a state file with no `pushed`: the floor stands in for the
    # history we can't reconstruct, and recording the key retires it.
    floor = ms("2026-08-06T10:00:00Z")
    pushed = set()
    meta, _, pending = spotify.build_payload(
        [
            item("t1", "Old", "2026-08-06T09:00:00Z"),
            item("t2", "New", "2026-08-06T11:00:00Z"),
        ],
        set(),
        pushed,
        prev_newest=floor,
        floor_ms=floor,
    )
    assert [m["identifier"] for m in meta] == ["t2"]  # only what's past the floor
    assert [p["identifier"] for p in pending] == ["t2"]
    assert key("t1", "2026-08-06T09:00:00Z") in pushed  # ...but t1 is accounted for


def test_payload_item_carries_the_fields_ryot_requires():
    meta, _, _ = spotify.build_payload(
        [item("t1", "One", "2026-08-06T10:00:00Z")], set(), set()
    )
    assert meta[0]["lot"] == "music" and meta[0]["source"] == "spotify"
    assert meta[0]["reviews"] == [] and meta[0]["collections"] == []
    seen = meta[0]["seen_history"][0]
    assert seen["progress"] == 100
    assert seen["providers_consumed_on"] == ["Spotify"]
    # A music listen has no manual_time_spent — Ryot takes the track duration.
    assert "manual_time_spent" not in seen


# ── get_recently_played ───────────────────────────────────────────────────────


def test_the_poll_never_sends_an_after_cursor():
    # `after` filters on played_at, so it would hide every late-syncing play.
    op = FakeOpener([json_reply({"items": []})])
    spotify.get_recently_played("tok", opener=op)
    assert "limit=50" in op.last.full_url
    assert "after" not in op.last.full_url


# ── main ──────────────────────────────────────────────────────────────────────


def test_main_fails_fast_on_missing_env(capsys):
    assert spotify.main(env={}) == 1
    assert "missing env" in capsys.readouterr().out


def test_main_end_to_end_persists_mark_known_pending_and_keys(tmp_path):
    # Reply queue: token refresh, recently-played, Ryot sink.
    op = FakeOpener(
        [
            json_reply({"access_token": "tok"}),
            json_reply({"items": [item("t1", "One", "2026-08-06T10:00:00Z")]}),
            json_reply({}, 200),
        ]
    )
    env = {**ENV, "STATE_DIR": str(tmp_path)}
    assert spotify.main(env=env, opener=op) == 0

    state = json.loads((tmp_path / "spotify-cursor.json").read_text())
    assert state == {
        "newest_ms": ms("2026-08-06T10:00:00Z"),
        "known": ["t1"],
        "pending": [
            {"identifier": "t1", "source_id": "One", "ended_on": "2026-08-06T10:00:00Z"}
        ],
        "pushed": [key("t1", "2026-08-06T10:00:00Z")],
    }
    assert op.requests[1].get_header("Authorization") == "Bearer tok"


def test_main_does_not_re_push_a_listen_already_in_the_key_set(tmp_path):
    (tmp_path / "spotify-cursor.json").write_text(
        json.dumps(
            {
                "newest_ms": ms("2026-08-06T10:00:00Z"),
                "known": ["t1"],
                "pending": [],
                "pushed": [key("t1", "2026-08-06T10:00:00Z")],
            }
        )
    )
    op = FakeOpener(
        [
            json_reply({"access_token": "tok"}),
            # The window still contains t1 — every poll sees the full 50.
            json_reply({"items": [item("t1", "One", "2026-08-06T10:00:00Z")]}),
        ]
    )
    assert spotify.main(env={**ENV, "STATE_DIR": str(tmp_path)}, opener=op) == 0
    assert len(op.requests) == 2  # token + poll, no sink call


def test_main_recovers_a_late_listen_behind_the_high_water_mark(tmp_path):
    (tmp_path / "spotify-cursor.json").write_text(
        json.dumps(
            {
                "newest_ms": ms("2026-08-06T12:00:00Z"),
                "known": ["t1"],
                "pending": [],
                "pushed": [key("t1", "2026-08-06T12:00:00Z")],
            }
        )
    )
    op = FakeOpener(
        [
            json_reply({"access_token": "tok"}),
            json_reply(
                {
                    "items": [
                        item("t1", "One", "2026-08-06T12:00:00Z"),  # already sent
                        item("t2", "Offline", "2026-08-06T08:00:00Z"),  # synced late
                    ]
                }
            ),
            json_reply({}, 200),
        ]
    )
    assert spotify.main(env={**ENV, "STATE_DIR": str(tmp_path)}, opener=op) == 0
    assert [m["identifier"] for m in op.body_of()["metadata"]] == ["t2"]


def test_main_migrates_a_state_file_written_before_per_listen_keys(tmp_path):
    # Legacy shape: `after_ms`, no `pushed`. The floor keeps the window from being
    # re-pushed wholesale, and the run records keys for all of it.
    (tmp_path / "spotify-cursor.json").write_text(
        json.dumps(
            {
                "after_ms": ms("2026-08-06T10:00:00Z"),
                "known": ["t1"],
                "pending": [],
            }
        )
    )
    op = FakeOpener(
        [
            json_reply({"access_token": "tok"}),
            json_reply(
                {
                    "items": [
                        item("t1", "Old", "2026-08-06T09:00:00Z"),  # pre-migration
                        item("t2", "New", "2026-08-06T11:00:00Z"),  # genuinely new
                    ]
                }
            ),
            json_reply({}, 200),
        ]
    )
    assert spotify.main(env={**ENV, "STATE_DIR": str(tmp_path)}, opener=op) == 0
    assert [m["identifier"] for m in op.body_of()["metadata"]] == ["t2"]

    state = json.loads((tmp_path / "spotify-cursor.json").read_text())
    assert state["newest_ms"] == ms("2026-08-06T11:00:00Z")
    assert state["pushed"] == sorted(
        [key("t1", "2026-08-06T09:00:00Z"), key("t2", "2026-08-06T11:00:00Z")]
    )
    assert "after_ms" not in state  # the legacy field is retired


def test_main_completes_last_runs_pending_tracks_on_the_next_run(tmp_path):
    (tmp_path / "spotify-cursor.json").write_text(
        json.dumps(
            {
                "newest_ms": ms("2026-08-06T10:00:00Z"),
                "known": ["t1"],
                "pending": [
                    {
                        "identifier": "t1",
                        "source_id": "One",
                        "ended_on": "2026-08-06T10:00:00Z",
                    }
                ],
                "pushed": [key("t1", "2026-08-06T10:00:00Z")],
            }
        )
    )
    op = FakeOpener(
        [
            json_reply({"access_token": "tok"}),
            json_reply({"items": []}),  # nothing new
            json_reply({}, 200),
        ]
    )
    assert spotify.main(env={**ENV, "STATE_DIR": str(tmp_path)}, opener=op) == 0

    pushed = op.body_of()["metadata"]
    assert [p["identifier"] for p in pushed] == ["t1"]  # the re-push that completes it
    state = json.loads((tmp_path / "spotify-cursor.json").read_text())
    assert state["pending"] == []  # and it is not re-pushed a third time


def test_main_does_not_post_when_there_is_nothing_to_send(tmp_path):
    op = FakeOpener([json_reply({"access_token": "tok"}), json_reply({"items": []})])
    assert spotify.main(env={**ENV, "STATE_DIR": str(tmp_path)}, opener=op) == 0
    assert len(op.requests) == 2  # token + poll, no sink call
    assert not (tmp_path / "spotify-cursor.json").exists()


def test_main_reports_failure_when_ryot_rejects_the_push(tmp_path):
    op = FakeOpener(
        [
            json_reply({"access_token": "tok"}),
            json_reply({"items": [item("t1", "One", "2026-08-06T10:00:00Z")]}),
            json_reply({}, 502),
        ]
    )
    assert spotify.main(env={**ENV, "STATE_DIR": str(tmp_path)}, opener=op) == 1
    # No key may be persisted for a listen Ryot never accepted, or the retry
    # would dedupe it away.
    assert not (tmp_path / "spotify-cursor.json").exists()
