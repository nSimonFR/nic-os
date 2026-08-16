"""immich-album-archive: the safety properties, mostly.

The interesting behaviour is what it refuses to do — write on a bare Config,
un-archive anything, touch a favourite, or treat a missing album as fatal — so
that is what most of these assert.
"""

import json

import pytest
from conftest import FakeOpener, json_reply

from nicos_scripts.immich import album_archive as aa

ALBUMS = [
    {"albumName": "WhatsApp", "id": "wa-id"},
    {"albumName": "Food", "id": "food-id"},
]


def page(items, next_page=None):
    return json_reply({"assets": {"items": items, "nextPage": next_page}})


def asset(aid, favorite=False):
    return {"id": aid, "isFavorite": favorite, "visibility": "timeline"}


@pytest.fixture
def cfg():
    return aa.Config(albums=("WhatsApp",), apply=True)


# ── Config ────────────────────────────────────────────────────────────────────


def test_a_config_built_with_no_environment_cannot_write():
    assert aa.Config.from_env({}).apply is False


def test_apply_needs_an_explicit_opt_in():
    assert aa.Config.from_env({"IMMICH_ARCHIVE_APPLY": "1"}).apply is True
    assert aa.Config.from_env({"IMMICH_ARCHIVE_APPLY": "0"}).apply is False
    assert aa.Config.from_env({"IMMICH_ARCHIVE_APPLY": ""}).apply is False


def test_album_names_are_split_and_stripped():
    cfg = aa.Config.from_env({"IMMICH_ARCHIVE_ALBUMS": "WhatsApp, Recently Saved ,"})
    assert cfg.albums == ("WhatsApp", "Recently Saved")


def test_trailing_slash_on_the_url_does_not_double_up():
    assert aa.Config.from_env({"IMMICH_URL": "http://x:2283/"}).url == "http://x:2283"


# ── the socket-activation gate ────────────────────────────────────────────────


class FakeRun:
    """Stands in for subprocess.run; records argv, replies with a fixed rc."""

    def __init__(self, returncode=0):
        self.returncode, self.calls = returncode, []

    def __call__(self, argv, check=False):
        self.calls.append(argv)
        return self


def test_no_gate_configured_means_always_run():
    assert aa.is_awake("", FakeRun(3)) is True


def test_the_gate_asks_systemctl_not_the_api():
    run = FakeRun(0)
    assert aa.is_awake("immich-server.service", run) is True
    assert run.calls == [["systemctl", "is-active", "--quiet", "immich-server.service"]]


def test_an_inactive_unit_closes_the_gate():
    assert aa.is_awake("immich-server.service", FakeRun(3)) is False


def test_no_systemctl_at_all_fails_open():
    def missing(argv, check=False):
        raise OSError("no systemctl")

    assert aa.is_awake("immich-server.service", missing) is True


def test_main_makes_no_request_when_immich_is_asleep(tmp_path, logged):
    lines, log = logged
    keyfile = tmp_path / "key"
    keyfile.write_text("secret\n")
    op = FakeOpener()
    env = {
        "IMMICH_API_KEY_FILE": str(keyfile),
        "IMMICH_ARCHIVE_ONLY_IF_AWAKE": "immich-server.service",
    }
    assert aa.main(env, op, log, FakeRun(3)) == 0
    assert op.requests == []
    assert any("asleep" in line for line in lines)


# ── album resolution ──────────────────────────────────────────────────────────


def test_albums_are_resolved_by_name_not_by_a_stored_id(cfg):
    op = FakeOpener([json_reply(ALBUMS)])
    assert aa.album_ids(cfg, "k", op) == {"WhatsApp": "wa-id"}


def test_a_missing_album_is_skipped_not_fatal(logged):
    lines, log = logged
    cfg = aa.Config(albums=("WhatsApp", "Nope"), apply=True)
    op = FakeOpener([json_reply(ALBUMS), page([])])
    assert aa.sweep(cfg, "k", op, log) == 0
    assert any("'Nope' not found" in line for line in lines)


# ── the query ─────────────────────────────────────────────────────────────────


def test_visibility_is_part_of_the_query_so_archived_assets_are_never_revisited(cfg):
    op = FakeOpener([page([])])
    aa.timeline_assets(cfg, "k", "wa-id", op)
    assert op.body_of() == {
        "albumIds": ["wa-id"], "visibility": "timeline", "size": aa.PAGE_SIZE, "page": 1,
    }


def test_pagination_follows_next_page_until_exhausted(cfg):
    op = FakeOpener([
        page([asset("a"), asset("b")], next_page="2"),
        page([asset("c")]),
    ])
    assert [a["id"] for a in aa.timeline_assets(cfg, "k", "wa-id", op)] == ["a", "b", "c"]
    assert op.body_of(0)["page"] == 1
    assert op.body_of(1)["page"] == 2


# ── what gets archived ────────────────────────────────────────────────────────


def test_favourites_are_left_on_the_timeline():
    assert aa.archivable([asset("a"), asset("b", favorite=True), asset("c")]) == ["a", "c"]


def test_the_write_only_ever_sets_archive(cfg):
    op = FakeOpener([json_reply({})])
    aa.archive(cfg, "k", ["a", "b"], op)
    body = op.body_of()
    assert body == {"ids": ["a", "b"], "visibility": "archive"}
    assert op.last.get_method() == "PUT"


def test_ids_are_chunked(cfg, monkeypatch):
    monkeypatch.setattr(aa, "CHUNK", 2)
    op = FakeOpener([json_reply({})])
    assert aa.archive(cfg, "k", ["a", "b", "c"], op) == 3
    assert [op.body_of(i)["ids"] for i in range(2)] == [["a", "b"], ["c"]]


# ── sweep ─────────────────────────────────────────────────────────────────────


def test_a_dry_run_reports_but_never_writes(logged):
    lines, log = logged
    op = FakeOpener([json_reply(ALBUMS), page([asset("a"), asset("b")])])
    assert aa.sweep(aa.Config(albums=("WhatsApp",)), "k", op, log) == 0
    assert any("DRY RUN, would archive 2" in line for line in lines)
    assert not any(r.get_method() == "PUT" for r in op.requests)


def test_a_steady_state_run_writes_nothing(cfg, logged):
    lines, log = logged
    op = FakeOpener([json_reply(ALBUMS), page([])])
    assert aa.sweep(cfg, "k", op, log) == 0
    assert not any(r.get_method() == "PUT" for r in op.requests)
    assert any("nothing new" in line for line in lines)


def test_an_album_of_nothing_but_favourites_writes_nothing(cfg, logged):
    lines, log = logged
    op = FakeOpener([json_reply(ALBUMS), page([asset("a", favorite=True)])])
    assert aa.sweep(cfg, "k", op, log) == 0
    assert not any(r.get_method() == "PUT" for r in op.requests)
    assert any("favourite" in line for line in lines)


def test_sweep_archives_the_new_arrivals(cfg, logged):
    lines, log = logged
    op = FakeOpener([
        json_reply(ALBUMS),
        page([asset("a"), asset("b", favorite=True), asset("c")]),
        json_reply({}),
    ])
    assert aa.sweep(cfg, "k", op, log) == 2
    put = [r for r in op.requests if r.get_method() == "PUT"]
    assert json.loads(put[0].data.decode())["ids"] == ["a", "c"]
    assert any("archived 2, left 1 favourite" in line for line in lines)


def test_immich_being_down_aborts_without_writing(cfg, logged):
    _, log = logged

    def boom(req, timeout=None):
        raise OSError("connection refused")

    with pytest.raises(aa.ImmichUnreachable):
        aa.sweep(cfg, "k", boom, log)


# ── main ──────────────────────────────────────────────────────────────────────


def test_main_is_tempfail_when_immich_is_down(tmp_path, logged):
    lines, log = logged
    keyfile = tmp_path / "key"
    keyfile.write_text("secret\n")

    def boom(req, timeout=None):
        raise OSError("connection refused")

    rc = aa.main({"IMMICH_API_KEY_FILE": str(keyfile)}, boom, log)
    assert rc == 75
    assert any("ABORT" in line for line in lines)


def test_main_fails_loudly_when_the_key_is_unreadable(tmp_path, logged):
    lines, log = logged
    rc = aa.main({"IMMICH_API_KEY_FILE": str(tmp_path / "absent")}, FakeOpener(), log)
    assert rc == 1
    assert any("FATAL" in line for line in lines)


def test_main_sends_the_key_as_the_api_header(tmp_path, logged):
    _, log = logged
    keyfile = tmp_path / "key"
    keyfile.write_text("secret\n")
    op = FakeOpener([json_reply(ALBUMS), page([])])
    assert aa.main({"IMMICH_API_KEY_FILE": str(keyfile)}, op, log) == 0
    assert op.requests[0].get_header("X-api-key") == "secret"
