"""Tests for the shared helpers (nicos_scripts.*)."""

import io
import json
import urllib.request

import pytest
from conftest import FakeOpener, FakeResponse, json_reply

from nicos_scripts import ryot
from nicos_scripts.httpjson import get_json, http_json, post_form, post_json
from nicos_scripts.logs import logger
from nicos_scripts.secrets import env_int, env_str, missing_env, read_secret
from nicos_scripts.state import ensure_dir, load_json, save_json


# ── logs ──────────────────────────────────────────────────────────────────────


def test_logger_prefixes_tag():
    out = io.StringIO()
    logger("steam-to-ryot", stream=out)("done")
    assert out.getvalue() == "[steam-to-ryot] done\n"


def test_logger_resolves_a_callable_stream_per_call():
    # travel-cal-sync logs to stderr; binding the object once would write to a
    # stale stream after anything (pytest, a redirect) swaps it.
    streams = [io.StringIO(), io.StringIO()]
    log = logger("t", stream=lambda: streams[-1])
    log("first")
    streams.append(io.StringIO())
    log("second")
    assert streams[1].getvalue() == "[t] first\n"
    assert streams[2].getvalue() == "[t] second\n"


# ── httpjson ──────────────────────────────────────────────────────────────────


def test_http_json_decodes_body():
    op = FakeOpener([json_reply({"a": 1})])
    assert http_json(urllib.request.Request("http://x"), opener=op) == {"a": 1}


def test_http_json_treats_empty_body_as_empty_object():
    # Ryot's sink answers 200 with no body; json.loads("") would raise.
    op = FakeOpener([lambda: FakeResponse(b"")])
    assert http_json(urllib.request.Request("http://x"), opener=op) == {}


def test_get_json_passes_headers():
    op = FakeOpener([json_reply({})])
    get_json("http://x", headers={"Authorization": "Bearer t"}, opener=op)
    assert op.last.get_header("Authorization") == "Bearer t"
    assert op.last.get_method() == "GET"


def test_post_form_urlencodes_and_keeps_extra_headers():
    op = FakeOpener([json_reply({"access_token": "tok"})])
    out = post_form(
        "http://x", {"grant_type": "refresh_token"}, headers={"Authorization": "Basic z"}, opener=op
    )
    assert out["access_token"] == "tok"
    assert op.last.data == b"grant_type=refresh_token"
    assert op.last.get_header("Content-type") == "application/x-www-form-urlencoded"
    assert op.last.get_header("Authorization") == "Basic z"


def test_post_json_returns_status_and_text():
    op = FakeOpener([lambda: FakeResponse(b"created", 201)])
    status, text = post_json("http://x", {"k": "v"}, opener=op)
    assert (status, text) == (201, "created")
    assert json.loads(op.last.data.decode()) == {"k": "v"}
    assert op.last.get_header("Content-type") == "application/json"


# ── state ─────────────────────────────────────────────────────────────────────


def test_load_json_returns_default_when_absent(tmp_path):
    assert load_json(str(tmp_path / "nope.json"), {"d": 1}) == {"d": 1}


def test_load_json_returns_default_when_corrupt(tmp_path):
    # A truncated cursor file must not wedge the timer unit forever.
    path = tmp_path / "cursor.json"
    path.write_text('{"after_ms": 17')
    assert load_json(str(path), {}) == {}


def test_save_json_roundtrips_and_leaves_no_tmp(tmp_path):
    path = str(tmp_path / "s.json")
    save_json(path, {"after_ms": 42})
    assert load_json(path, None) == {"after_ms": 42}
    assert not (tmp_path / "s.json.tmp").exists()


def test_save_json_overwrites_atomically(tmp_path):
    path = str(tmp_path / "s.json")
    save_json(path, {"v": 1})
    save_json(path, {"v": 2})
    assert load_json(path, None) == {"v": 2}


def test_ensure_dir_is_idempotent(tmp_path):
    d = str(tmp_path / "state")
    assert ensure_dir(d) == d
    ensure_dir(d)


# ── secrets / env ─────────────────────────────────────────────────────────────


def test_env_helpers_read_the_passed_mapping():
    env = {"A": "x", "N": "7"}
    assert env_str("A", "", env) == "x"
    assert env_str("MISSING", "fallback", env) == "fallback"
    assert env_int("N", 1, env) == 7


@pytest.mark.parametrize("raw", ["", "   ", "not-a-number"])
def test_env_int_falls_back_on_garbage(raw):
    # A malformed EnvironmentFile value must not crash before the first log line.
    assert env_int("N", 3, {"N": raw}) == 3


def test_missing_env_flags_unset_and_empty():
    env = {"SET": "v", "EMPTY": ""}
    assert missing_env(("SET", "EMPTY", "ABSENT"), env) == ["EMPTY", "ABSENT"]


def test_read_secret_strips_the_trailing_newline(tmp_path):
    path = tmp_path / "token"
    path.write_text("s3cret\n")
    assert read_secret(str(path)) == "s3cret"


# ── ryot ──────────────────────────────────────────────────────────────────────


def test_metadata_item_always_carries_reviews_and_collections():
    # Non-optional in ImportOrExportMetadataItem: omitting either makes Ryot's
    # strict deserialize drop the whole item, silently.
    item = ryot.metadata_item("music", "spotify", "id", "name", [])
    assert item["reviews"] == []
    assert item["collections"] == []


def test_seen_omits_manual_time_spent_unless_given():
    assert "manual_time_spent" not in ryot.seen("2026-08-06T00:00:00+00:00")
    timed = ryot.seen("2026-08-06T00:00:00+00:00", manual_time_spent="600")
    assert timed["manual_time_spent"] == "600"
    assert timed["progress"] == 100


def test_post_export_wraps_metadata_in_a_complete_export_body():
    op = FakeOpener([json_reply({}, 202)])
    status, _ = ryot.post_export("http://ryot/_i/slug", [{"lot": "music"}], opener=op)
    assert status == 202
    assert op.body_of() == {"metadata": [{"lot": "music"}]}


@pytest.mark.parametrize(
    ("status", "ok"), [(200, True), (201, True), (202, True), (204, False), (500, False)]
)
def test_is_ok_accepts_the_three_statuses_ryot_uses(status, ok):
    assert ryot.is_ok(status) is ok


def test_graphql_returns_data_and_sends_bearer_token():
    op = FakeOpener([json_reply({"data": {"createOrUpdateUserMeasurement": "ts"}})])
    data = ryot.graphql("http://ryot/graphql", "tok", "mutation{}", {"i": 1}, opener=op)
    assert data == {"createOrUpdateUserMeasurement": "ts"}
    assert op.last.get_header("Authorization") == "Bearer tok"
    assert op.body_of() == {"query": "mutation{}", "variables": {"i": 1}}


def test_graphql_raises_on_graphql_level_errors():
    # GraphQL errors come back inside a 200 — a status check alone reports success.
    op = FakeOpener([json_reply({"errors": [{"message": "nope"}]})])
    with pytest.raises(RuntimeError, match="nope"):
        ryot.graphql("http://ryot/graphql", "tok", "q", {}, opener=op)
