"""spotify-backfill: export parsing, V1-overlap planning, dry run vs --apply."""

import json

from conftest import FakeOpener, json_reply

from nicos_scripts.connectors import spotify
from nicos_scripts.connectors import spotify_backfill as bf

MIN = 60 * 1000


def rec(tid, ts, ms_played=200000, name="Song"):
    return {
        "ts": ts,
        "ms_played": ms_played,
        "spotify_track_uri": f"spotify:track:{tid}" if tid else None,
        "master_metadata_track_name": name,
    }


def ms(iso):
    return spotify.iso_to_ms(iso)


def rows(items):
    return {"items": items, "pageInfo": {"hasMore": False, "nextCursor": None}}


# ── parse_export ──────────────────────────────────────────────────────────────


def test_parse_export_keeps_tracks_played_30s_or_more():
    plays, filtered, dups = bf.parse_export(
        [
            rec("t2", "2024-01-01T12:00:00Z"),
            rec("t1", "2024-01-01T11:00:00Z", ms_played=30000),
            rec("t3", "2024-01-01T13:00:00Z", ms_played=29999),  # skipped
            rec(None, "2024-01-01T14:00:00Z"),  # podcast episode
            rec("t2", "2024-01-01T12:00:00Z"),  # same record twice across files
        ]
    )
    assert [p["track_id"] for p in plays] == ["t1", "t2"]  # sorted by time
    assert (filtered, dups) == (2, 1)
    assert plays[0]["ms"] == ms("2024-01-01T11:00:00Z")


# ── plan ──────────────────────────────────────────────────────────────────────


def play(tid, iso, ms_played=180000):
    return {"track_id": tid, "name": tid, "ms": ms(iso), "ms_played": ms_played}


def ev(eid, iso, consumed_on="Spotify"):
    return {"id": eid, "ms": ms(iso), "consumed_on": consumed_on}


def actions(plan):
    return [(a, p["track_id"], e["id"] if e else None) for a, p, e in plan]


def test_plan_corrects_a_v1_complete_stamped_after_the_play():
    out = bf.plan(
        [play("t1", "2024-01-01T10:00:00Z")],
        {"t1": "met_1"},
        {"met_1": [ev("e1", "2024-01-01T11:05:00Z")]},
    )
    assert actions(out) == [("correct", "t1", "e1")]


def test_plan_does_not_reach_past_90_minutes_or_before_the_slack():
    out = bf.plan(
        [play("t1", "2024-01-01T10:00:00Z")],
        {"t1": "met_1"},
        {"met_1": [ev("late", "2024-01-01T11:31:00Z"), ev("early", "2024-01-01T09:54:00Z")]},
    )
    assert actions(out) == [("new", "t1", None)]


def test_plan_only_corrects_spotify_completes():
    out = bf.plan(
        [play("t1", "2024-01-01T10:00:00Z")],
        {"t1": "met_1"},
        {"met_1": [ev("e1", "2024-01-01T10:10:00Z", consumed_on="YouTube Music")]},
    )
    assert actions(out) == [("new", "t1", None)]


def test_plan_lets_each_event_stand_for_one_play():
    # Two plays 4 min apart, one V1 event after both: one correction, one new.
    out = bf.plan(
        [play("t1", "2024-01-01T10:00:00Z"), play("t1", "2024-01-01T10:04:00Z")],
        {"t1": "met_1"},
        {"met_1": [ev("e1", "2024-01-01T10:30:00Z")]},
    )
    assert sorted(a for a, _, _ in actions(out)) == ["correct", "new"]


def test_plan_exact_matches_win_over_an_earlier_plays_overlap():
    # e2 is exactly the second play (already corrected/created): the first play
    # must not steal it as a V1 overlap.
    out = bf.plan(
        [play("t1", "2024-01-01T10:00:00Z"), play("t1", "2024-01-01T10:20:00Z")],
        {"t1": "met_1"},
        {"met_1": [ev("e2", "2024-01-01T10:20:00Z")]},
    )
    assert actions(out) == [("new", "t1", None), ("exists", "t1", "e2")]


def test_plan_marks_tracks_without_an_entity_unresolved():
    out = bf.plan([play("t9", "2024-01-01T10:00:00Z")], {}, {})
    assert actions(out) == [("unresolved", "t9", None)]


def test_a_rerun_after_apply_finds_everything_in_place():
    p = play("t1", "2024-01-01T10:00:00Z")
    out = bf.plan([p], {"t1": "met_1"}, {"met_1": [ev("e1", "2024-01-01T10:00:00Z")]})
    assert actions(out) == [("exists", "t1", "e1")]


def test_written_shapes_carry_the_real_start_and_end():
    p = play("t1", "2024-01-01T10:00:00Z", ms_played=3 * MIN)
    assert bf.new_event("met_1", p) == {
        "entityId": "met_1",
        "eventSchemaSlug": "complete",
        "occurredAt": "2024-01-01T10:00:00.000Z",
        "properties": {"consumedOn": "Spotify", "startedOn": "2024-01-01T09:57:00.000Z"},
    }
    assert bf.correction(p) == {
        "occurredAt": "2024-01-01T10:00:00.000Z",
        "properties": {"set": {"startedOn": "2024-01-01T09:57:00.000Z"}, "remove": []},
    }


# ── create_events ─────────────────────────────────────────────────────────────


def test_create_events_waits_out_a_pending_batch():
    from nicos_scripts import ryot

    op = FakeOpener(
        [
            json_reply({"operationId": "op1", "status": "accepted", "writtenCount": 0}, 202),
            json_reply({"operationId": "op1", "result": {"count": 2}}),
        ]
    )
    c = ryot.Client("http://ryot", "key", opener=op, sleep=lambda _s: None)
    assert bf.create_events(c, [{}, {}], sleep=lambda _s: None, log=lambda _m: None) == 2
    assert op.last.full_url.endswith("/api/events/operations/op1")


# ── main ──────────────────────────────────────────────────────────────────────


def export(tmp_path, records):
    path = tmp_path / "Streaming_History_Audio_2024.json"
    path.write_text(json.dumps(records))
    return str(path)


def lookup(tracks):
    return json_reply(
        {
            "data": {
                "p": rows([{"id": "prov"}]),
                "t": rows([{"id": e, "externalId": t, "providerId": "prov"} for t, e in tracks.items()]),
            }
        }
    )


def completes(events):
    return json_reply({"data": {"c": rows(events)}})


RECORDS = [
    rec("t1", "2024-01-01T10:00:00Z"),  # overlaps a V1 event
    rec("t2", "2024-01-01T11:00:00Z"),  # new
    rec("t3", "2024-01-01T12:00:00Z"),  # unknown track
    rec("t1", "2024-01-01T13:00:00Z", ms_played=1000),  # too short
]
V1_EVENT = {"id": "e1", "entityId": "met_1", "occurredAt": "2024-01-01T11:02:00.000Z", "consumedOn": "Spotify"}


def run(tmp_path, argv, replies):
    op = FakeOpener(replies)
    lines = []
    env = {"RYOT_API_KEY": "key", "RYOT_URL": "http://ryot", "STATE_DIR": str(tmp_path / "state")}
    rc = bf.main(argv, env=env, opener=op, sleep=lambda _s: None, log=lines.append)
    return rc, op, lines


def test_dry_run_writes_nothing_and_summarizes(tmp_path):
    path = export(tmp_path, RECORDS)
    rc, op, lines = run(
        tmp_path, [path], [lookup({"t1": "met_1", "t2": "met_2"}), completes([V1_EVENT])]
    )
    assert rc == 0
    assert all(r.get_method() == "POST" and r.full_url.endswith("/ryotql/execute") for r in op.requests)
    summary = next(line for line in lines if line.startswith("dry run:"))
    assert "1 new, 1 to correct" in summary
    assert "1 on tracks to import" in summary and "1 filtered" in summary
    assert not (tmp_path / "state").exists()


def test_apply_imports_corrects_and_creates(tmp_path):
    path = export(tmp_path, RECORDS)
    rc, op, lines = run(
        tmp_path,
        ["--apply", path],
        [
            lookup({"t1": "met_1", "t2": "met_2"}),
            json_reply({"jobId": "j3"}),
            json_reply({"status": "completed", "data": {"id": "met_3"}}),
            completes([V1_EVENT]),
            json_reply({"eventId": "e1", "warnings": []}),
            json_reply({"count": 2, "outcomes": [], "failure": None}, 201),
        ],
    )
    assert rc == 0, lines
    patch = next(r for r in op.requests if r.get_method() == "PATCH")
    assert patch.full_url.endswith("/api/events/e1")
    assert json.loads(patch.data)["occurredAt"] == "2024-01-01T10:00:00.000Z"
    created = json.loads(op.last.data)
    assert [e["entityId"] for e in created] == ["met_2", "met_3"]
    cache = json.loads((tmp_path / "state" / "spotify-entities.json").read_text())
    assert cache == {"t1": "met_1", "t2": "met_2", "t3": "met_3"}


def test_a_partial_batch_fails_the_run(tmp_path):
    path = export(tmp_path, [rec("t2", "2024-01-01T11:00:00Z")])
    rc, _, _ = run(
        tmp_path,
        ["--apply", path],
        [
            lookup({"t2": "met_2"}),
            completes([]),
            json_reply({"count": 0, "outcomes": [], "failure": {"code": "policy-rejected"}}, 201),
        ],
    )
    assert rc == 1


def test_missing_api_key_is_fatal(tmp_path):
    lines = []
    assert bf.main([export(tmp_path, RECORDS)], env={}, log=lines.append) == 1
    assert "missing env" in lines[0]
