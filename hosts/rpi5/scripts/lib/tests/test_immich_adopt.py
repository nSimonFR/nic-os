"""immich-adopt: the Live Photo ordering, the safe defaults, the partial-failure
path. No network — every call goes through the `opener` seam.
"""

import json

import pytest

from nicos_scripts.immich import adopt
from conftest import FakeResponse, json_reply

ME = "3933e084-nico"
THEM = "1a9ab4c5-bastien"
SRC = "9471acd1-source"
DST = "f4b34838-target"

# Config.from_env falls back to the real agenix path, which exists on the Pi but
# not in the Nix sandbox. Every from_env test pins it somewhere absent so the
# suite reads the same on both — otherwise these assertions quietly depend on
# whether the host happens to have the secret.
NO_KEY = {"IMMICH_API_KEY_FILE": "/nonexistent/immich-api-key"}


def env(**kw):
    return {**NO_KEY, **kw}


def cfg(**kw):
    base = {
        "url": "http://immich",
        "key": "k",
        "source": SRC,
        "target": DST,
        "dry_run": False,
        "replace": False,
    }
    base.update(kw)
    return adopt.Config(**base)


def still(asset_id, name="IMG.HEIC", owner=THEM, motion=None):
    return {
        "id": asset_id,
        "ownerId": owner,
        "originalFileName": name,
        "fileCreatedAt": "2026-08-22T15:53:48.554Z",
        "fileModifiedAt": "2026-08-22T17:02:23.000Z",
        "livePhotoVideoId": motion,
        "duration": None,
        "visibility": "timeline",
    }


def search_reply(items, next_page=None):
    return json_reply(
        {"assets": {"items": items, "total": len(items), "count": len(items),
                    "nextPage": next_page}}
    )


def album_reply(name):
    return json_reply({"id": "x", "albumName": name, "assetCount": 0})


def upload_reply(asset_id, status="created"):
    return json_reply({"id": asset_id, "status": status})


def bulk_reply(ids, success=True):
    return json_reply([{"id": i, "success": success} for i in ids])


def paths(fake):
    return [r.full_url.replace("http://immich", "") for r in fake.requests]


def methods(fake):
    return [(r.get_method(), r.full_url.replace("http://immich", "")) for r in fake.requests]


# --- config: the safe defaults -----------------------------------------------

def test_empty_env_cannot_write_or_replace():
    c = adopt.Config.from_env(env())
    assert c.dry_run is True
    assert c.replace is False


def test_dry_run_needs_an_explicit_zero():
    assert adopt.Config.from_env(env(IMMICH_ADOPT_DRY_RUN="0")).dry_run is False
    for raw in ("1", "", "no", "false", "true"):
        assert adopt.Config.from_env(env(IMMICH_ADOPT_DRY_RUN=raw)).dry_run is True


def test_replace_needs_an_explicit_one():
    assert adopt.Config.from_env(env(IMMICH_ADOPT_REPLACE="1")).replace is True
    for raw in ("0", "", "yes", "true"):
        assert adopt.Config.from_env(env(IMMICH_ADOPT_REPLACE=raw)).replace is False


def test_target_defaults_to_source():
    assert cfg(target="").target_album == SRC
    assert cfg(target=DST).target_album == DST


def test_missing_key_and_source_are_fatal():
    with pytest.raises(adopt.AdoptError):
        adopt.adopt_album(cfg(key=""))
    with pytest.raises(adopt.AdoptError):
        adopt.adopt_album(cfg(source=""))


# --- dry run ------------------------------------------------------------------

def test_dry_run_writes_nothing(opener, logged):
    lines, log = logged
    fake = opener([
        json_reply({"id": ME}),
        album_reply("Nico & Bastien"),
        album_reply("Bastien x Nico"),
        search_reply([still("a1"), still("a2")]),
    ])
    assert adopt.adopt_album(cfg(dry_run=True), opener=fake, log=log) == []
    assert not any(m == "POST" and p == "/api/assets" for m, p in methods(fake))
    assert not any(m in ("PUT", "DELETE") for m, _ in methods(fake))
    assert sum("would adopt" in x for x in lines) == 2


def test_my_own_assets_are_never_adopted(opener, logged):
    lines, log = logged
    fake = opener([
        json_reply({"id": ME}),
        album_reply("src"),
        album_reply("dst"),
        search_reply([still("mine", owner=ME), still("mine2", owner=ME)]),
    ])
    assert adopt.adopt_album(cfg(), opener=fake, log=log) == []
    assert any("nothing to adopt" in x for x in lines)


# --- the Live Photo ordering ---------------------------------------------------

def test_motion_video_is_uploaded_before_the_still_that_links_it(opener, logged):
    lines, log = logged
    fake = opener([
        json_reply({"id": ME}),
        album_reply("src"),
        album_reply("dst"),
        search_reply([still("still1", motion="mov1")]),
        json_reply(still("mov1", name="IMG.MOV")),   # GET the motion asset
        FakeResponse(b"MOVBYTES"),                   # its original
        upload_reply("new-mov"),                     # upload motion
        FakeResponse(b"HEICBYTES"),                  # still original
        upload_reply("new-still"),                   # upload still
        bulk_reply(["new-still"]),
    ])
    adopt.adopt_album(cfg(), opener=fake, log=log)

    uploads = [r for r in fake.requests if r.get_method() == "POST"
               and r.full_url.endswith("/api/assets")]
    assert len(uploads) == 2
    motion_body, still_body = (u.data.decode("latin-1") for u in uploads)

    # The motion half goes first, hidden, and carries no link of its own.
    assert "MOVBYTES" in motion_body
    assert 'name="visibility"\r\n\r\nhidden' in motion_body
    assert "livePhotoVideoId" not in motion_body
    # The still then links to the id the server just gave me for the motion.
    assert "HEICBYTES" in still_body
    assert 'name="livePhotoVideoId"\r\n\r\nnew-mov' in still_body
    assert "visibility" not in still_body


def test_plain_asset_skips_the_motion_path_entirely(opener, logged):
    lines, log = logged
    fake = opener([
        json_reply({"id": ME}),
        album_reply("src"),
        album_reply("dst"),
        search_reply([still("s1", motion=None)]),
        FakeResponse(b"JPEG"),
        upload_reply("new1"),
        bulk_reply(["new1"]),
    ])
    adopt.adopt_album(cfg(), opener=fake, log=log)
    uploads = [r for r in fake.requests if r.get_method() == "POST"
               and r.full_url.endswith("/api/assets")]
    assert len(uploads) == 1
    assert "livePhotoVideoId" not in uploads[0].data.decode("latin-1")


def test_upload_carries_over_dates_and_filename(opener, logged):
    lines, log = logged
    fake = opener([
        json_reply({"id": ME}),
        album_reply("src"),
        album_reply("dst"),
        search_reply([still("s1", name="IMG_1430.HEIC")]),
        FakeResponse(b"X"),
        upload_reply("new1"),
        bulk_reply(["new1"]),
    ])
    adopt.adopt_album(cfg(), opener=fake, log=log)
    body = [r for r in fake.requests if r.get_method() == "POST"
            and r.full_url.endswith("/api/assets")][0].data.decode("latin-1")
    assert 'name="fileCreatedAt"\r\n\r\n2026-08-22T15:53:48.554Z' in body
    assert 'name="fileModifiedAt"\r\n\r\n2026-08-22T17:02:23.000Z' in body
    assert 'filename="IMG_1430.HEIC"' in body
    # duration is None here and must be omitted, not sent as the string "None"
    assert "None" not in body


# --- idempotency --------------------------------------------------------------

def test_duplicate_status_is_reused_not_retried(opener, logged):
    lines, log = logged
    fake = opener([
        json_reply({"id": ME}),
        album_reply("src"),
        album_reply("dst"),
        search_reply([still("s1")]),
        FakeResponse(b"X"),
        upload_reply("already-mine", status="duplicate"),
        bulk_reply(["already-mine"]),
    ])
    got = adopt.adopt_album(cfg(), opener=fake, log=log)
    assert got == [("s1", "already-mine")]
    added = [r for r in fake.requests if r.get_method() == "PUT"][0]
    assert json.loads(added.data.decode())["ids"] == ["already-mine"]


# --- pagination ---------------------------------------------------------------

def test_album_assets_follows_next_page(opener):
    fake = opener([
        search_reply([still("a")], next_page="2"),
        search_reply([still("b")], next_page=None),
    ])
    got = adopt.album_assets(cfg(), SRC, opener=fake)
    assert [a["id"] for a in got] == ["a", "b"]
    assert json.loads(fake.requests[0].data.decode())["page"] == 1
    assert json.loads(fake.requests[1].data.decode())["page"] == 2


# --- replace: the destructive path -------------------------------------------

def test_replace_off_leaves_the_sharers_entry_alone(opener, logged):
    lines, log = logged
    fake = opener([
        json_reply({"id": ME}),
        album_reply("src"),
        album_reply("dst"),
        search_reply([still("s1")]),
        FakeResponse(b"X"),
        upload_reply("new1"),
        bulk_reply(["new1"]),
    ])
    adopt.adopt_album(cfg(replace=False), opener=fake, log=log)
    assert not any(m == "DELETE" for m, _ in methods(fake))


def test_replace_removes_only_originals_whose_copy_landed(opener, logged):
    lines, log = logged
    fake = opener([
        json_reply({"id": ME}),
        album_reply("src"),
        album_reply("dst"),
        search_reply([still("s1"), still("s2")]),
        FakeResponse(b"A"), upload_reply("new1"),
        FakeResponse(b"B"), upload_reply("new2"),
        # new2 failed to land in the target album...
        json_reply([{"id": "new1", "success": True},
                    {"id": "new2", "success": False}]),
        bulk_reply(["s1"]),
    ])
    adopt.adopt_album(cfg(replace=True), opener=fake, log=log)
    deleted = [r for r in fake.requests if r.get_method() == "DELETE"]
    assert len(deleted) == 1
    # ...so only s1's original entry may be removed. s2's must survive.
    assert json.loads(deleted[0].data.decode())["ids"] == ["s1"]


def test_replace_reports_a_refusal_instead_of_pretending(opener, logged):
    lines, log = logged
    fake = opener([
        json_reply({"id": ME}),
        album_reply("Nico & Bastien"),
        album_reply("dst"),
        search_reply([still("s1")]),
        FakeResponse(b"X"), upload_reply("new1"),
        bulk_reply(["new1"]),
        # Not my album -> the server refuses the removal per-asset.
        json_reply([{"id": "s1", "success": False, "error": "no_permission"}]),
    ])
    adopt.adopt_album(cfg(replace=True), opener=fake, log=log)
    assert any("refused" in x for x in lines)
    assert any("removed 0/1" in x for x in lines)


# --- partial failure ----------------------------------------------------------

def test_one_bad_asset_does_not_abandon_the_rest(opener, logged):
    lines, log = logged

    def boom():
        raise OSError("truncated download")

    fake = opener([
        json_reply({"id": ME}),
        album_reply("src"),
        album_reply("dst"),
        search_reply([still("bad"), still("good")]),
        boom,
        FakeResponse(b"OK"), upload_reply("new-good"),
        bulk_reply(["new-good"]),
    ])
    got = adopt.adopt_album(cfg(), opener=fake, log=log)
    assert got == [("good", "new-good")]
    assert any("FAILED" in x for x in lines)


# --- argv ---------------------------------------------------------------------

def seen_config(monkeypatch, argv, env):
    """Run main() and hand back the Config it built, without doing any I/O."""
    captured = {}
    monkeypatch.setattr(
        adopt, "adopt_album", lambda c, opener=None, log=None: captured.setdefault("cfg", c)
    )
    rc = adopt.main(argv=argv, env=env)
    return rc, captured["cfg"]


def test_flags_override_the_safe_env_defaults(monkeypatch):
    e = env(IMMICH_ADOPT_SOURCE=SRC)
    rc, c = seen_config(monkeypatch, ["--apply", "--replace", "--target", DST], e)
    assert rc == 0
    assert (c.dry_run, c.replace, c.source, c.target) == (False, True, SRC, DST)


def test_without_flags_env_safe_defaults_survive(monkeypatch):
    e = env(IMMICH_ADOPT_SOURCE=SRC)
    _, c = seen_config(monkeypatch, [], e)
    assert c.dry_run is True and c.replace is False


def test_source_flag_wins_over_the_environment(monkeypatch):
    e = env(IMMICH_ADOPT_SOURCE="env-album")
    _, c = seen_config(monkeypatch, ["--source", SRC], e)
    assert c.source == SRC


def test_missing_key_exits_nonzero_not_traceback(opener):
    fake = opener([json_reply({})])
    assert adopt.main(argv=["--source", SRC], env=env(), opener=fake) == 1
