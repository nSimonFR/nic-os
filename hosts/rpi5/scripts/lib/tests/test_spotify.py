"""spotify-to-ryot: per-listen dedupe and the V2 activity log."""

import io
import json
import urllib.error

from conftest import FakeOpener, json_reply

from nicos_scripts import ryot
from nicos_scripts.connectors import spotify

ENV = {
    "SPOTIFY_CLIENT_ID": "cid",
    "SPOTIFY_CLIENT_SECRET": "csec",
    "SPOTIFY_REFRESH_TOKEN": "rtok",
    "RYOT_API_KEY": "key",
    "RYOT_URL": "http://ryot",
}


def item(track_id, name, played_at):
    return {"played_at": played_at, "track": {"id": track_id, "name": name}}


def ms(iso):
    return spotify.iso_to_ms(iso)


def key(track_id, iso):
    return spotify.listen_key(track_id, ms(iso))


def rows(items):
    return {"items": items, "pageInfo": {"hasMore": False, "nextCursor": None}}


def lookup_reply(tracks, provider="prov"):
    """RyotQL reply to resolve_entities: provider + {track id: entity id}."""
    return json_reply(
        {
            "data": {
                "p": rows([{"id": provider}]),
                "t": rows(
                    [{"id": e, "externalId": t, "providerId": provider} for t, e in tracks.items()]
                ),
            }
        }
    )


def completes_reply(events=()):
    return json_reply({"data": {"c": rows(list(events))}})


SAVED = json_reply({"result": {"count": 1, "status": "saved"}})


def http_error(code, body):
    def raise_():
        raise urllib.error.HTTPError("http://ryot", code, "err", {}, io.BytesIO(body.encode()))

    return raise_


def run(tmp_path, replies, state=None, entities=None, log=None):
    if state is not None:
        (tmp_path / "spotify-cursor.json").write_text(json.dumps(state))
    if entities is not None:
        (tmp_path / "spotify-entities.json").write_text(json.dumps(entities))
    op = FakeOpener(replies)
    lines = []
    rc = spotify.main(
        env={**ENV, "STATE_DIR": str(tmp_path)},
        opener=op,
        sleep=lambda _s: None,
        log=log or lines.append,
    )
    return rc, op, lines


def saved_state(tmp_path):
    return json.loads((tmp_path / "spotify-cursor.json").read_text())


def ops(op):
    """Bodies of the media-activity-log calls."""
    return [
        json.loads(r.data.decode())
        for r in op.requests
        if r.full_url.endswith("/operations/media-activity-log")
    ]


# ── listen identity ───────────────────────────────────────────────────────────


def test_iso_to_ms_handles_the_trailing_z_and_millis():
    assert spotify.iso_to_ms("1970-01-01T00:00:01Z") == 1000
    assert spotify.iso_to_ms("1970-01-01T00:00:01.500Z") == 1500


def test_iso_to_ms_assumes_utc_when_no_offset_is_given():
    assert spotify.iso_to_ms("1970-01-01T00:00:01") == 1000


def test_ms_to_iso_round_trips():
    assert spotify.ms_to_iso(ms("2026-08-06T10:00:00.123Z")) == "2026-08-06T10:00:00.123Z"


def test_key_ms_round_trips_a_listen_key():
    assert spotify.key_ms(spotify.listen_key("t1", 1234)) == 1234


def test_key_ms_returns_none_for_a_malformed_key():
    assert spotify.key_ms("no-timestamp-here") is None


def test_prune_keys_drops_only_what_is_past_the_horizon():
    newest = ms("2026-08-06T10:00:00Z")
    fresh = spotify.listen_key("t1", newest - 1000)
    stale = spotify.listen_key("t2", newest - spotify.RETAIN_MS - 1000)
    assert spotify.prune_keys({fresh, stale, "garbage"}, newest) == [fresh]


def test_prune_keys_keeps_everything_when_there_is_no_high_water_mark():
    k = spotify.listen_key("t1", 5)
    assert spotify.prune_keys({k}, None) == [k]


# ── new_listens ───────────────────────────────────────────────────────────────


def test_new_listens_skips_already_pushed_keys():
    out, _ = spotify.new_listens(
        [item("t1", "One", "2026-08-06T10:00:00Z"), item("t2", "Two", "2026-08-06T10:30:00Z")],
        {key("t1", "2026-08-06T10:00:00Z")},
    )
    assert [x["track_id"] for x in out] == ["t2"]


def test_a_listen_that_syncs_late_from_an_offline_device_is_still_logged():
    # The regression this dedupe exists for: a phone play keeps its original
    # played_at, so it arrives *behind* everything already pushed.
    out, _ = spotify.new_listens(
        [item("t1", "Offline", "2026-08-06T08:00:00Z")],
        {key("t9", "2026-08-06T12:00:00Z")},
    )
    assert [x["track_id"] for x in out] == ["t1"]


def test_the_same_track_at_a_different_time_is_a_distinct_listen():
    out, _ = spotify.new_listens(
        [item("t1", "One", "2026-08-06T14:00:00Z")], {key("t1", "2026-08-06T10:00:00Z")}
    )
    assert len(out) == 1


def test_items_without_a_track_id_or_timestamp_are_skipped():
    out, retired = spotify.new_listens(
        [
            {"played_at": "2026-08-06T10:00:00Z", "track": {}},
            {"track": {"id": "t1", "name": "One"}},
            {"played_at": "2026-08-06T10:00:00Z"},
        ],
        set(),
    )
    assert out == [] and retired == []


def test_the_bootstrap_floor_retires_old_keys_without_logging_them():
    out, retired = spotify.new_listens(
        [item("t1", "Old", "2026-08-06T09:00:00Z"), item("t2", "New", "2026-08-06T11:00:00Z")],
        set(),
        floor_ms=ms("2026-08-06T10:00:00Z"),
    )
    assert [x["track_id"] for x in out] == ["t2"]
    assert retired == [key("t1", "2026-08-06T09:00:00Z")]


def test_v1_pending_listens_are_matched_against_lagged_completes():
    (p,) = spotify.v1_pending_listens(
        [{"identifier": "t1", "source_id": "One", "ended_on": "2026-08-06T10:00:00Z"}]
    )
    assert p["key"] == key("t1", "2026-08-06T10:00:00Z") and p["v1_overlap"]


# ── already_logged / payload ──────────────────────────────────────────────────


def test_an_exact_timestamp_match_is_already_logged():
    lsn = spotify.listen("t1", "One", 1000)
    assert spotify.already_logged([{"ms": 1000}], lsn)
    assert not spotify.already_logged([{"ms": 2000}], lsn)


def test_a_v1_pending_listen_matches_a_complete_up_to_90_min_later():
    lsn = spotify.listen("t1", "One", 0, v1_overlap=True)
    assert spotify.already_logged([{"ms": 65 * 60 * 1000}], lsn)
    assert not spotify.already_logged([{"ms": 91 * 60 * 1000}], lsn)
    assert not spotify.already_logged([{"ms": -1000}], lsn)


def test_activity_payload_is_a_dated_complete_keyed_on_the_listen():
    lsn = spotify.listen("t1", "One", ms("2026-08-06T10:00:00.250Z"))
    p = spotify.activity_payload("met_1", lsn)
    assert p == {
        "submissionId": f"spotify-t1-{lsn['ms']}",
        "submittedAt": "2026-08-06T10:00:00.250Z",
        "entry": {
            "kind": "complete",
            "entityId": "met_1",
            "when": {"kind": "date", "finishedOn": "2026-08-06T10:00:00.250Z"},
            "consumedOn": "Spotify",
        },
    }
    # The same listen always builds the same payload (idempotency-key replay).
    assert spotify.activity_payload("met_1", dict(lsn)) == p


# ── get_recently_played ───────────────────────────────────────────────────────


def test_the_poll_never_sends_an_after_cursor():
    op = FakeOpener([json_reply({"items": []})])
    spotify.get_recently_played("tok", opener=op)
    assert "limit=50" in op.last.full_url
    assert "after" not in op.last.full_url


# ── resolve_entities ──────────────────────────────────────────────────────────


def client(replies):
    op = FakeOpener(replies)
    return ryot.Client("http://ryot", "key", opener=op, sleep=lambda _s: None), op


def test_resolve_uses_the_cache_without_calling_ryot():
    c, op = client([json_reply({})])
    emap = {"t1": "met_1"}
    assert spotify.resolve_entities(c, ["t1"], emap) == []
    assert op.requests == []


def test_resolve_ignores_entities_of_another_provider_and_imports_the_rest():
    c, op = client(
        [
            json_reply(
                {
                    "data": {
                        "p": rows([{"id": "prov"}]),
                        "t": rows(
                            [
                                {"id": "met_1", "externalId": "t1", "providerId": "prov"},
                                {"id": "met_x", "externalId": "t2", "providerId": "other"},
                            ]
                        ),
                    }
                }
            ),
            json_reply({"jobId": "job/1"}),
            json_reply({"status": "completed", "data": {"id": "met_2"}}),
        ]
    )
    emap = {}
    assert spotify.resolve_entities(c, ["t1", "t2"], emap, log=lambda _m: None) == []
    assert emap == {"t1": "met_1", "t2": "met_2"}
    assert op.body_of(1) == {"providerId": "prov", "externalId": "t2"}
    assert op.requests[2].full_url.endswith("/imports/job%2F1")  # job ids are quoted


def test_resolve_reports_a_failed_import_as_unresolved():
    c, _ = client(
        [
            lookup_reply({}),
            json_reply({"jobId": "j"}),
            json_reply({"status": "failed"}),
        ]
    )
    emap = {}
    assert spotify.resolve_entities(c, ["t1"], emap, log=lambda _m: None) == ["t1"]
    assert emap == {}


def test_resolve_without_imports_returns_the_missing_ids():
    c, op = client([lookup_reply({})])
    assert spotify.resolve_entities(c, ["t1"], {}, import_missing=False) == ["t1"]
    assert len(op.requests) == 1


# ── ryot.Client pacing ────────────────────────────────────────────────────────


def test_client_retries_after_a_rate_limit_for_the_advertised_wait():
    waits = []
    op = FakeOpener(
        [
            http_error(429, json.dumps({"reason": {"retryAfterMs": 5000}})),
            json_reply({"ok": True}),
        ]
    )
    c = ryot.Client("http://ryot", "key", opener=op, sleep=waits.append)
    assert c.request("GET", "/x") == {"ok": True}
    assert waits == [6.0, ryot.API_PAUSE_SEC]  # the advertised wait, then the pace


def test_client_folds_a_non_429_error_into_runtime_error():
    op = FakeOpener([http_error(400, '{"_tag":"Bad"}')])
    c = ryot.Client("http://ryot", "key", opener=op, sleep=lambda _s: None)
    try:
        c.request("POST", "/x", {})
    except RuntimeError as e:
        assert "400" in str(e) and "Bad" in str(e)
        assert not isinstance(e, ryot.RateLimited)
    else:
        raise AssertionError("expected RuntimeError")


def test_query_all_follows_the_cursor():
    op = FakeOpener(
        [
            json_reply({"data": {"c": {"items": [1], "pageInfo": {"hasMore": True, "nextCursor": "n"}}}}),
            json_reply({"data": {"c": rows([2])}}),
        ]
    )
    c = ryot.Client("http://ryot", "key", opener=op, sleep=lambda _s: None)
    q = spotify.completes_query(["met_1"], 0)
    assert c.query_all("c", q) == [1, 2]
    assert op.body_of(1)["queries"]["c"]["output"]["pagination"]["after"] == "n"
    assert "after" not in q["output"]["pagination"]  # the caller's query is untouched


# ── main ──────────────────────────────────────────────────────────────────────


def test_main_fails_fast_on_missing_env(capsys):
    assert spotify.main(env={}) == 1
    assert "missing env" in capsys.readouterr().out


def test_main_logs_a_new_listen_with_its_real_played_at(tmp_path):
    rc, op, _ = run(
        tmp_path,
        [
            json_reply({"access_token": "tok"}),
            json_reply({"items": [item("t1", "One", "2026-08-06T10:00:00Z")]}),
            lookup_reply({"t1": "met_1"}),
            completes_reply(),
            SAVED,
        ],
    )
    assert rc == 0
    (body,) = ops(op)
    assert body["idempotencyKey"] == body["payload"]["submissionId"]
    assert body["payload"]["entry"]["when"] == {"kind": "date", "finishedOn": "2026-08-06T10:00:00.000Z"}
    assert op.last.get_header("X-api-key") == "key"
    assert saved_state(tmp_path) == {
        "newest_ms": ms("2026-08-06T10:00:00Z"),
        "pushed": [key("t1", "2026-08-06T10:00:00Z")],
    }
    assert json.loads((tmp_path / "spotify-entities.json").read_text()) == {"t1": "met_1"}


def test_main_does_not_call_ryot_for_a_listen_already_pushed(tmp_path):
    state = {"newest_ms": ms("2026-08-06T10:00:00Z"), "pushed": [key("t1", "2026-08-06T10:00:00Z")]}
    rc, op, _ = run(
        tmp_path,
        [
            json_reply({"access_token": "tok"}),
            json_reply({"items": [item("t1", "One", "2026-08-06T10:00:00Z")]}),
        ],
        state=state,
    )
    assert rc == 0
    assert len(op.requests) == 2  # token + poll


def test_main_records_but_does_not_relog_a_listen_ryot_already_has(tmp_path):
    # State lost or a crash between the write and the save: the exact complete
    # already in Ryot stands for the listen.
    rc, op, _ = run(
        tmp_path,
        [
            json_reply({"access_token": "tok"}),
            json_reply({"items": [item("t1", "One", "2026-08-06T10:00:00Z")]}),
            completes_reply(
                [{"id": "ev1", "entityId": "met_1", "occurredAt": "2026-08-06T10:00:00.000Z"}]
            ),
        ],
        entities={"t1": "met_1"},
    )
    assert rc == 0
    assert ops(op) == []
    assert saved_state(tmp_path)["pushed"] == [key("t1", "2026-08-06T10:00:00Z")]


def test_main_recovers_a_late_listen_behind_the_high_water_mark(tmp_path):
    state = {"newest_ms": ms("2026-08-06T12:00:00Z"), "pushed": [key("t1", "2026-08-06T12:00:00Z")]}
    rc, op, _ = run(
        tmp_path,
        [
            json_reply({"access_token": "tok"}),
            json_reply(
                {
                    "items": [
                        item("t1", "One", "2026-08-06T12:00:00Z"),
                        item("t2", "Offline", "2026-08-06T08:00:00Z"),
                    ]
                }
            ),
            completes_reply(),
            SAVED,
        ],
        state=state,
        entities={"t1": "met_1", "t2": "met_2"},
    )
    assert rc == 0
    assert [b["payload"]["entry"]["entityId"] for b in ops(op)] == ["met_2"]
    s = saved_state(tmp_path)
    assert s["newest_ms"] == ms("2026-08-06T12:00:00Z")  # never drags backwards
    assert key("t2", "2026-08-06T08:00:00Z") in s["pushed"]


def test_main_cuts_over_from_a_v1_state_file(tmp_path):
    # V1 shape: known/pending + pushed. The pending listen V1 never completed is
    # logged at its real time; `known`/`pending` are dropped.
    state = {
        "newest_ms": ms("2026-08-06T10:00:00Z"),
        "known": ["t1"],
        "pending": [{"identifier": "t1", "source_id": "One", "ended_on": "2026-08-06T10:00:00Z"}],
        "pushed": [key("t1", "2026-08-06T10:00:00Z")],
    }
    rc, op, _ = run(
        tmp_path,
        [json_reply({"access_token": "tok"}), json_reply({"items": []})],
        state=state,
    )
    assert rc == 0
    # The pending key is already in `pushed` (V1 sent it): nothing to re-log.
    assert ops(op) == []
    assert saved_state(tmp_path) == {
        "newest_ms": ms("2026-08-06T10:00:00Z"),
        "pushed": [key("t1", "2026-08-06T10:00:00Z")],
    }


def test_main_skips_a_v1_pending_listen_that_v1_did_complete(tmp_path):
    state = {
        "newest_ms": ms("2026-08-06T09:00:00Z"),
        "known": ["t1"],
        "pending": [{"identifier": "t1", "source_id": "One", "ended_on": "2026-08-06T10:00:00Z"}],
        "pushed": [],
    }
    rc, op, _ = run(
        tmp_path,
        [
            json_reply({"access_token": "tok"}),
            json_reply({"items": []}),
            completes_reply(
                # V1's completion re-push, ~1 h after the play.
                [{"id": "ev1", "entityId": "met_1", "occurredAt": "2026-08-06T11:02:00.000Z"}]
            ),
        ],
        state=state,
        entities={"t1": "met_1"},
    )
    assert rc == 0
    assert ops(op) == []
    assert saved_state(tmp_path)["pushed"] == [key("t1", "2026-08-06T10:00:00Z")]


def test_main_migrates_a_state_file_written_before_per_listen_keys(tmp_path):
    state = {"after_ms": ms("2026-08-06T10:00:00Z"), "known": ["t1"], "pending": []}
    rc, op, _ = run(
        tmp_path,
        [
            json_reply({"access_token": "tok"}),
            json_reply(
                {
                    "items": [
                        item("t1", "Old", "2026-08-06T09:00:00Z"),
                        item("t2", "New", "2026-08-06T11:00:00Z"),
                    ]
                }
            ),
            completes_reply(),
            SAVED,
        ],
        state=state,
        entities={"t1": "met_1", "t2": "met_2"},
    )
    assert rc == 0
    assert [b["payload"]["entry"]["entityId"] for b in ops(op)] == ["met_2"]
    s = saved_state(tmp_path)
    assert s["newest_ms"] == ms("2026-08-06T11:00:00Z")
    assert s["pushed"] == sorted(
        [key("t1", "2026-08-06T09:00:00Z"), key("t2", "2026-08-06T11:00:00Z")]
    )


def test_main_does_not_write_state_when_there_is_nothing_to_do(tmp_path):
    rc, op, _ = run(tmp_path, [json_reply({"access_token": "tok"}), json_reply({"items": []})])
    assert rc == 0
    assert len(op.requests) == 2
    assert not (tmp_path / "spotify-cursor.json").exists()


def test_a_refused_listen_is_not_recorded_and_fails_the_run(tmp_path):
    rc, _, lines = run(
        tmp_path,
        [
            json_reply({"access_token": "tok"}),
            json_reply({"items": [item("t1", "One", "2026-08-06T10:00:00Z")]}),
            completes_reply(),
            json_reply({"result": {"kind": "invalid"}}),
        ],
        entities={"t1": "met_1"},
    )
    assert rc == 1
    assert saved_state(tmp_path)["pushed"] == []  # retried next run
    assert any("refused" in line for line in lines)


def test_a_ryot_outage_keeps_the_keys_of_what_was_already_logged(tmp_path):
    rc, _, _ = run(
        tmp_path,
        [
            json_reply({"access_token": "tok"}),
            json_reply(
                {
                    "items": [
                        item("t1", "One", "2026-08-06T10:00:00Z"),
                        item("t2", "Two", "2026-08-06T11:00:00Z"),
                    ]
                }
            ),
            completes_reply(),
            SAVED,
            http_error(502, "bad gateway"),
        ],
        entities={"t1": "met_1", "t2": "met_2"},
    )
    assert rc == 1
    assert saved_state(tmp_path)["pushed"] == [key("t1", "2026-08-06T10:00:00Z")]
