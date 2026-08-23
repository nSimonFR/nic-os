"""immich-adopt: the Live Photo ordering, the safe defaults, re-run state, and
the partial-failure path. No network — every call goes through the `opener` seam.

These use a URL-routing fake rather than conftest's ordered queue on purpose: the
interesting assertions here are about *which* calls happen and in what order
relative to each other (motion before still), not about the incidental order the
implementation happens to fetch its album metadata in. A positional queue turns
every such refactor into a spurious test failure.
"""

import json

import pytest

from nicos_scripts.immich import adopt

ME = "3933e084-nico"
THEM = "1a9ab4c5-bastien"
SRC = "9471acd1-source"
DST = "f4b34838-target"

# Config.from_env falls back to the real agenix path, which exists on the Pi but
# not in the Nix sandbox. Every from_env test pins it somewhere absent so the
# suite reads the same on both.
NO_KEY = {"IMMICH_API_KEY_FILE": "/nonexistent/immich-api-key"}


def env(**kw):
    return {**NO_KEY, **kw}


class Router:
    """A urlopen stand-in that answers by URL, and records everything.

    `on(method, needle, *bodies)` queues replies for requests whose method
    matches and whose URL contains `needle` (longest needle wins, so
    `/original` beats the bare asset route). The last body repeats.
    """

    def __init__(self):
        self.routes = {}
        self.calls = []

    def on(self, method, needle, *bodies):
        self.routes[(method, needle)] = list(bodies)
        return self

    def json(self, method, needle, *objs):
        return self.on(method, needle, *[json.dumps(o).encode() for o in objs])

    def __call__(self, req, timeout=None):
        method, url = req.get_method(), req.full_url
        self.calls.append((method, url.replace("http://immich", ""), req.data))
        matches = [k for k in self.routes if k[0] == method and k[1] in url]
        if not matches:
            raise AssertionError(f"unrouted {method} {url}")
        bodies = self.routes[max(matches, key=lambda k: len(k[1]))]
        body = bodies.pop(0) if len(bodies) > 1 else bodies[0]
        if callable(body):
            body = body()
        return _Resp(body)

    # -- introspection ---------------------------------------------------------
    def paths(self, method=None):
        return [p for m, p, _ in self.calls if method in (None, m)]

    def bodies(self, method, needle):
        return [d for m, p, d in self.calls if m == method and needle in p]

    def uploads(self):
        return [d.decode("latin-1") for d in self.bodies("POST", "/api/assets")]


class _Resp:
    def __init__(self, body):
        self._body = body
        self.status = 200

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


_STATE_DIR = None


@pytest.fixture(autouse=True)
def _isolate_state(tmp_path):
    """No test may read or write the real /var/lib state file."""
    global _STATE_DIR
    _STATE_DIR = tmp_path
    yield
    _STATE_DIR = None


def cfg(tmp=None, **kw):
    base = {
        "url": "http://immich",
        "key": "k",
        "source": SRC,
        "target": DST,
        "state_path": str(tmp or (_STATE_DIR / "state.json")),
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


def base_router(assets, album_names=("src", "dst"), me=ME):
    """The calls every album-mode run makes before the per-asset work."""
    r = Router()
    r.json("GET", "/api/users/me", {"id": me})
    r.json("GET", f"/api/albums/{SRC}", {"id": SRC, "albumName": album_names[0]})
    r.json("GET", f"/api/albums/{DST}", {"id": DST, "albumName": album_names[1]})
    r.json("POST", "/api/search/metadata", {
        "assets": {"items": assets, "total": len(assets), "count": len(assets),
                   "nextPage": None}
    })
    return r


def owner_router(buckets, columns, me=ME):
    r = Router()
    r.json("GET", "/api/users/me", {"id": me})
    r.json("GET", f"/api/albums/{DST}", {"id": DST, "albumName": "dst"})
    r.json("GET", "/api/timeline/buckets", buckets)
    for bucket, cols in columns.items():
        r.json("GET", f"timeBucket={bucket}", cols)
    return r


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


def test_target_defaults_to_source_album():
    assert cfg(target="").target_album == SRC
    assert cfg(target=DST).target_album == DST


@pytest.mark.parametrize("bad", [
    {"key": ""},                                          # no api key
    {"source": "", "owner": ""},                          # no source at all
    {"source": "", "owner": "u1", "target": ""},          # owner mode, no album
    {"source": "", "owner": "u1", "replace": True},       # replace with no album
])
def test_unusable_config_is_fatal(bad):
    with pytest.raises(adopt.AdoptError):
        adopt.run(cfg(**bad))


# --- dry run ------------------------------------------------------------------

def test_dry_run_writes_nothing(logged):
    lines, log = logged
    r = base_router([still("a1"), still("a2")])
    assert adopt.run(cfg(dry_run=True), opener=r, log=log) == []
    assert "/api/assets" not in r.paths("POST")
    assert r.paths("PUT") == [] and r.paths("DELETE") == []
    assert sum("would adopt" in x for x in lines) == 2


def test_my_own_assets_are_never_adopted(logged):
    lines, log = logged
    r = base_router([still("mine", owner=ME), still("mine2", owner=ME)])
    r.json("PUT", "/assets", [])
    assert adopt.run(cfg(), opener=r, log=log) == []
    assert "/api/assets" not in r.paths("POST")


# --- the Live Photo ordering ---------------------------------------------------

def test_motion_video_is_uploaded_before_the_still_that_links_it(logged):
    lines, log = logged
    r = base_router([still("still1", motion="mov1")])
    r.json("GET", "/api/assets/mov1", still("mov1", name="IMG.MOV"))
    r.on("GET", "/api/assets/mov1/original", b"MOVBYTES")
    r.on("GET", "/api/assets/still1/original", b"HEICBYTES")
    r.json("POST", "/api/assets",
           {"id": "new-mov", "status": "created"},
           {"id": "new-still", "status": "created"})
    r.json("PUT", "/assets", [{"id": "new-still", "success": True}])

    adopt.run(cfg(), opener=r, log=log)

    motion_body, still_body = r.uploads()
    # The motion half goes first, hidden, and carries no link of its own.
    assert "MOVBYTES" in motion_body
    assert 'name="visibility"\r\n\r\nhidden' in motion_body
    assert "livePhotoVideoId" not in motion_body
    # The still then links to the id the server just gave me for the motion.
    assert "HEICBYTES" in still_body
    assert 'name="livePhotoVideoId"\r\n\r\nnew-mov' in still_body
    assert "visibility" not in still_body


def test_plain_asset_skips_the_motion_path_entirely(logged):
    lines, log = logged
    r = base_router([still("s1", motion=None)])
    r.on("GET", "/api/assets/s1/original", b"JPEG")
    r.json("POST", "/api/assets", {"id": "new1", "status": "created"})
    r.json("PUT", "/assets", [{"id": "new1", "success": True}])
    adopt.run(cfg(), opener=r, log=log)
    assert len(r.uploads()) == 1
    assert "livePhotoVideoId" not in r.uploads()[0]


def test_upload_carries_over_dates_and_filename(logged):
    lines, log = logged
    r = base_router([still("s1", name="IMG_1430.HEIC")])
    r.on("GET", "/api/assets/s1/original", b"X")
    r.json("POST", "/api/assets", {"id": "new1", "status": "created"})
    r.json("PUT", "/assets", [{"id": "new1", "success": True}])
    adopt.run(cfg(), opener=r, log=log)
    body = r.uploads()[0]
    assert 'name="fileCreatedAt"\r\n\r\n2026-08-22T15:53:48.554Z' in body
    assert 'name="fileModifiedAt"\r\n\r\n2026-08-22T17:02:23.000Z' in body
    assert 'filename="IMG_1430.HEIC"' in body
    # duration is None here and must be omitted, not sent as the string "None"
    assert "None" not in body


# --- idempotency: the server's half, and ours --------------------------------

def test_duplicate_upload_status_is_reused_not_retried(logged):
    lines, log = logged
    r = base_router([still("s1")])
    r.on("GET", "/api/assets/s1/original", b"X")
    r.json("POST", "/api/assets", {"id": "already-mine", "status": "duplicate"})
    r.json("PUT", "/assets", [{"id": "already-mine", "success": True}])
    assert adopt.run(cfg(), opener=r, log=log) == [("s1", "already-mine")]
    assert json.loads(r.bodies("PUT", "/assets")[0])["ids"] == ["already-mine"]


def test_state_stops_a_second_run_re_downloading(tmp_path, logged):
    lines, log = logged
    state = tmp_path / "state.json"

    def run_once():
        r = base_router([still("s1")])
        r.on("GET", "/api/assets/s1/original", b"X")
        r.json("POST", "/api/assets", {"id": "new1", "status": "created"})
        r.json("PUT", "/assets", [{"id": "new1", "success": False, "error": "duplicate"}])
        adopt.run(cfg(tmp=state), opener=r, log=log)
        return r

    first = run_once()
    assert len(first.uploads()) == 1
    assert json.loads(state.read_text())["adopted"] == {"s1": "new1"}

    second = run_once()
    assert second.uploads() == []                                    # no re-upload
    assert "/api/assets/s1/original" not in second.paths("GET")      # no re-download
    # ...but membership is still re-asserted, so a hand-removed copy comes back.
    assert json.loads(second.bodies("PUT", "/assets")[0])["ids"] == ["new1"]


def test_unwritable_state_warns_but_still_adds_to_the_album(logged):
    lines, log = logged
    r = base_router([still("s1")])
    r.on("GET", "/api/assets/s1/original", b"X")
    r.json("POST", "/api/assets", {"id": "new1", "status": "created"})
    r.json("PUT", "/assets", [{"id": "new1", "success": True}])
    # An unwritable cursor must not abort the run: the upload already happened,
    # and skipping the album add would leave the copy orphaned outside it.
    adopt.run(cfg(tmp="/nonexistent/dir/state.json"), opener=r, log=log)
    assert any("could not save state" in x for x in lines)
    assert json.loads(r.bodies("PUT", "/assets")[0])["ids"] == ["new1"]


# --- pagination ---------------------------------------------------------------

def test_album_assets_follows_next_page():
    r = Router()
    r.json("POST", "/api/search/metadata",
           {"assets": {"items": [still("a")], "total": 1, "count": 1, "nextPage": "2"}},
           {"assets": {"items": [still("b")], "total": 1, "count": 1, "nextPage": None}})
    got = adopt.album_assets(cfg(), SRC, opener=r)
    assert [a["id"] for a in got] == ["a", "b"]
    pages = [json.loads(b)["page"] for b in r.bodies("POST", "/api/search/metadata")]
    assert pages == [1, 2]


# --- owner mode ---------------------------------------------------------------

def test_owner_mode_walks_every_bucket_and_only_timeline_visibility():
    r = owner_router(
        [{"timeBucket": "2026-07-01", "count": 2}, {"timeBucket": "2026-06-01", "count": 1}],
        {
            "2026-07-01": {"id": ["a", "b"], "ownerId": ["u1", "u1"],
                           "livePhotoVideoId": [None, "mov"]},
            "2026-06-01": {"id": ["c"], "ownerId": ["u1"], "livePhotoVideoId": [None]},
        },
    )
    got = adopt.owner_assets(cfg(owner="u1"), "u1", opener=r)
    assert [a["id"] for a in got] == ["a", "b", "c"]
    assert got[1]["livePhotoVideoId"] == "mov"
    # The enumeration must never pick up hidden assets: a motion half is adopted
    # through its still, and on its own it would become a stray timeline video.
    timeline_calls = [p for p in r.paths("GET") if "/api/timeline/" in p]
    assert timeline_calls and all("visibility=timeline" in p for p in timeline_calls)


def test_owner_mode_fetches_detail_for_the_stub_it_adopts(logged):
    lines, log = logged
    r = owner_router(
        [{"timeBucket": "2026-07-01", "count": 1}],
        {"2026-07-01": {"id": ["s1"], "ownerId": [THEM], "livePhotoVideoId": [None]}},
    )
    # The timeline stub carries no fileModifiedAt, so run() must go and get it.
    r.json("GET", "/api/assets/s1", still("s1", name="ALFIE.HEIC"))
    r.on("GET", "/api/assets/s1/original", b"BYTES")
    r.json("POST", "/api/assets", {"id": "new1", "status": "created"})
    r.json("PUT", "/assets", [{"id": "new1", "success": True}])

    adopt.run(cfg(source="", owner=THEM), opener=r, log=log)
    assert "/api/assets/s1" in r.paths("GET")
    assert 'filename="ALFIE.HEIC"' in r.uploads()[0]


def test_owner_mode_never_adopts_my_own_uploads(logged):
    lines, log = logged
    r = owner_router(
        [{"timeBucket": "2026-07-01", "count": 2}],
        {"2026-07-01": {"id": ["mine", "theirs"], "ownerId": [ME, THEM],
                        "livePhotoVideoId": [None, None]}},
    )
    r.json("GET", "/api/assets/theirs", still("theirs"))
    r.on("GET", "/api/assets/theirs/original", b"B")
    r.json("POST", "/api/assets", {"id": "new1", "status": "created"})
    r.json("PUT", "/assets", [{"id": "new1", "success": True}])
    adopt.run(cfg(source="", owner=THEM), opener=r, log=log)
    assert len(r.uploads()) == 1
    assert "/api/assets/mine" not in r.paths("GET")


# --- replace: the destructive path -------------------------------------------

def test_replace_off_leaves_the_sharers_entry_alone(logged):
    lines, log = logged
    r = base_router([still("s1")])
    r.on("GET", "/api/assets/s1/original", b"X")
    r.json("POST", "/api/assets", {"id": "new1", "status": "created"})
    r.json("PUT", "/assets", [{"id": "new1", "success": True}])
    adopt.run(cfg(replace=False), opener=r, log=log)
    assert r.paths("DELETE") == []


def test_replace_removes_only_originals_whose_copy_landed(logged):
    lines, log = logged
    r = base_router([still("s1"), still("s2")])
    r.on("GET", "/api/assets/s1/original", b"A")
    r.on("GET", "/api/assets/s2/original", b"B")
    r.json("POST", "/api/assets",
           {"id": "new1", "status": "created"}, {"id": "new2", "status": "created"})
    # new2 never made it into the target album.
    r.json("PUT", "/assets", [{"id": "new1", "success": True},
                              {"id": "new2", "success": False, "error": "no_permission"}])
    r.json("DELETE", "/assets", [{"id": "s1", "success": True}])

    adopt.run(cfg(replace=True), opener=r, log=log)
    # ...so only s1's original entry may go. s2's must survive.
    assert json.loads(r.bodies("DELETE", "/assets")[0])["ids"] == ["s1"]


def test_replace_counts_an_already_in_album_copy_as_landed(tmp_path, logged):
    lines, log = logged
    state = tmp_path / "s.json"
    r = base_router([still("s1"), still("s2")])
    r.on("GET", "/api/assets/s1/original", b"A")
    r.on("GET", "/api/assets/s2/original", b"B")
    r.json("POST", "/api/assets",
           {"id": "new1", "status": "created"}, {"id": "new2", "status": "duplicate"})
    # `duplicate` on the PUT means "already in this album" — that is landed, and
    # must not be lumped in with a real permission refusal.
    r.json("PUT", "/assets", [{"id": "new1", "success": True},
                              {"id": "new2", "success": False, "error": "duplicate"}])
    r.json("DELETE", "/assets", [{"id": "s1", "success": True}, {"id": "s2", "success": True}])
    adopt.run(cfg(tmp=state, replace=True), opener=r, log=log)
    assert json.loads(r.bodies("DELETE", "/assets")[0])["ids"] == ["s1", "s2"]


def test_replace_reports_a_refusal_instead_of_pretending(logged):
    lines, log = logged
    r = base_router([still("s1")], album_names=("Nico & Bastien", "dst"))
    r.on("GET", "/api/assets/s1/original", b"X")
    r.json("POST", "/api/assets", {"id": "new1", "status": "created"})
    r.json("PUT", "/assets", [{"id": "new1", "success": True}])
    # Not my album -> the server refuses the removal per-asset.
    r.json("DELETE", "/assets", [{"id": "s1", "success": False, "error": "no_permission"}])
    adopt.run(cfg(replace=True), opener=r, log=log)
    assert any("refused" in x for x in lines)
    assert any("removed 0/1" in x for x in lines)


# --- partial failure ----------------------------------------------------------

def test_one_bad_asset_does_not_abandon_the_rest(tmp_path, logged):
    lines, log = logged
    state = tmp_path / "s.json"

    def boom():
        raise OSError("truncated download")

    r = base_router([still("bad"), still("good")])
    r.on("GET", "/api/assets/bad/original", boom)
    r.on("GET", "/api/assets/good/original", b"OK")
    r.json("POST", "/api/assets", {"id": "new-good", "status": "created"})
    r.json("PUT", "/assets", [{"id": "new-good", "success": True}])

    assert adopt.run(cfg(tmp=state), opener=r, log=log) == [("good", "new-good")]
    assert any("FAILED" in x for x in lines)
    # The failure must not be recorded as adopted, or it is never retried.
    assert json.loads(state.read_text())["adopted"] == {"good": "new-good"}


# --- argv ---------------------------------------------------------------------

def seen_config(monkeypatch, argv, env):
    """Run main() and hand back the Config it built, without doing any I/O."""
    captured = {}
    monkeypatch.setattr(
        adopt, "run", lambda c, opener=None, log=None: captured.setdefault("cfg", c)
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


def test_from_owner_flag_lands_on_the_config(monkeypatch):
    _, c = seen_config(monkeypatch, ["--from-owner", THEM, "--target", DST], env())
    assert (c.owner, c.target, c.source) == (THEM, DST, "")


def test_source_and_from_owner_are_mutually_exclusive():
    with pytest.raises(SystemExit):
        adopt.main(argv=["--source", SRC, "--from-owner", THEM], env=env())


def test_missing_key_exits_nonzero_not_traceback():
    assert adopt.main(argv=["--source", SRC], env=env(), opener=Router()) == 1
