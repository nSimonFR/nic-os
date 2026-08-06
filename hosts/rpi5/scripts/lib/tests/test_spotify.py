"""spotify-to-ryot: cursor arithmetic and the two-phase completion."""

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


# ── iso_to_ms ─────────────────────────────────────────────────────────────────


def test_iso_to_ms_handles_the_trailing_z_and_millis():
    assert spotify.iso_to_ms("1970-01-01T00:00:01Z") == 1000
    assert spotify.iso_to_ms("1970-01-01T00:00:01.500Z") == 1500


def test_iso_to_ms_assumes_utc_when_no_offset_is_given():
    assert spotify.iso_to_ms("1970-01-01T00:00:01") == 1000


# ── build_payload ─────────────────────────────────────────────────────────────


def test_first_run_pushes_every_listen_and_records_the_cursor():
    known = set()
    meta, cursor, pending = spotify.build_payload(
        [item("t1", "One", "2026-08-06T10:00:00Z"), item("t2", "Two", "2026-08-06T11:00:00Z")],
        None,
        known,
    )
    assert [m["identifier"] for m in meta] == ["t1", "t2"]
    assert cursor == spotify.iso_to_ms("2026-08-06T11:00:00Z")
    assert [p["identifier"] for p in pending] == ["t1", "t2"]
    assert known == {"t1", "t2"}


def test_listens_at_or_before_the_cursor_are_dropped():
    # Spotify's `after` is exclusive on our side too — an overlapping poll must
    # not re-push a listen we already sent.
    after = spotify.iso_to_ms("2026-08-06T10:00:00Z")
    meta, cursor, _ = spotify.build_payload(
        [item("t1", "One", "2026-08-06T10:00:00Z"), item("t2", "Two", "2026-08-06T10:30:00Z")],
        after,
        set(),
    )
    assert [m["identifier"] for m in meta] == ["t2"]
    assert cursor == spotify.iso_to_ms("2026-08-06T10:30:00Z")


def test_a_known_track_is_pushed_but_not_queued_for_completion():
    # Its metadata already exists in Ryot, so the seen completes immediately;
    # re-pushing it next run would duplicate the listen.
    meta, _, pending = spotify.build_payload(
        [item("t1", "One", "2026-08-06T10:00:00Z")], None, {"t1"}
    )
    assert len(meta) == 1
    assert pending == []


def test_items_without_a_track_id_or_timestamp_are_skipped():
    meta, cursor, _ = spotify.build_payload(
        [
            {"played_at": "2026-08-06T10:00:00Z", "track": {}},
            {"track": {"id": "t1", "name": "One"}},
            {"played_at": "2026-08-06T10:00:00Z"},
        ],
        None,
        set(),
    )
    assert meta == []
    assert cursor == 0


def test_cursor_never_moves_backwards_on_an_empty_poll():
    after = spotify.iso_to_ms("2026-08-06T10:00:00Z")
    _, cursor, _ = spotify.build_payload([], after, set())
    assert cursor == after


def test_payload_item_carries_the_fields_ryot_requires():
    meta, _, _ = spotify.build_payload(
        [item("t1", "One", "2026-08-06T10:00:00Z")], None, set()
    )
    assert meta[0]["lot"] == "music" and meta[0]["source"] == "spotify"
    assert meta[0]["reviews"] == [] and meta[0]["collections"] == []
    seen = meta[0]["seen_history"][0]
    assert seen["progress"] == 100
    assert seen["providers_consumed_on"] == ["Spotify"]
    # A music listen has no manual_time_spent — Ryot takes the track duration.
    assert "manual_time_spent" not in seen


# ── main ──────────────────────────────────────────────────────────────────────


def test_main_fails_fast_on_missing_env(capsys):
    assert spotify.main(env={}) == 1
    assert "missing env" in capsys.readouterr().out


def test_main_end_to_end_persists_cursor_known_and_pending(tmp_path):
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
        "after_ms": spotify.iso_to_ms("2026-08-06T10:00:00Z"),
        "known": ["t1"],
        "pending": [
            {"identifier": "t1", "source_id": "One", "ended_on": "2026-08-06T10:00:00Z"}
        ],
    }
    assert op.requests[1].get_header("Authorization") == "Bearer tok"


def test_main_completes_last_runs_pending_tracks_on_the_next_run(tmp_path):
    (tmp_path / "spotify-cursor.json").write_text(
        json.dumps(
            {
                "after_ms": spotify.iso_to_ms("2026-08-06T10:00:00Z"),
                "known": ["t1"],
                "pending": [
                    {
                        "identifier": "t1",
                        "source_id": "One",
                        "ended_on": "2026-08-06T10:00:00Z",
                    }
                ],
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

    pushed = json.loads(op.requests[-1].data.decode())["metadata"]
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
    # The cursor must not advance past a listen Ryot never accepted.
    assert not (tmp_path / "spotify-cursor.json").exists()
