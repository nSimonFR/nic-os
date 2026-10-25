"""plex-to-ryot: incremental views, anime mapping, dedupe and the cursor."""

import io
import json
import urllib.error
import urllib.parse

from conftest import FakeResponse

from nicos_scripts.connectors import plex

PLEX = "http://plex:32400"
TOKEN = "secret-plex-token"
T0 = 1_790_000_000  # bootstrap: the newest Plex event already in Ryot
PROVIDERS = {"movie.tmdb": "pm", "show.tmdb": "ps", "anime.anilist": "pa"}

# Fribb rows (compacted): [anilist, tvdb, tmdb_tv, season, episode_offset]
FRIBB = [
    {"anilist_id": 162147, "tvdb_id": 431703, "themoviedb_id": {"tv": 221301},
     "season": {"tvdb": 1, "tmdb": 1}},
    {"anilist_id": 175035, "tvdb_id": 431703, "themoviedb_id": {"tv": 221301},
     "season": {"tvdb": 1, "tmdb": 1}, "episode_offset": {"tvdb": 4, "tmdb": 4}},
    {"anilist_id": 145139, "tvdb_id": 348545, "themoviedb_id": {"tv": 85937},
     "season": {"tvdb": 4, "tmdb": 4}},
    {"anilist_id": 235, "tvdb_id": 72454, "themoviedb_id": {"tv": 30983}, "season": None},
    {"anilist_id": 779, "tvdb_id": 72454, "themoviedb_id": {"tv": 30983},
     "season": {"tvdb": 0, "tmdb": 0}},
    {"anilist_id": None, "tvdb_id": 1, "themoviedb_id": {"tv": 2}},
    {"anilist_id": 9, "themoviedb_id": {"movie": [129]}},
]
INDEX = plex.compact_fribb(FRIBB)


def movie(rk, title, at, tmdb, **kw):
    return {"ratingKey": rk, "title": title, "lastViewedAt": at, "viewCount": 1,
            "Guid": [{"id": f"tmdb://{tmdb}"}, {"id": "imdb://tt1"}], **kw}


def episode(rk, show_rk, s, e, at, tmdb_ep="", **kw):
    g = [{"id": f"tmdb://{tmdb_ep}"}] if tmdb_ep else []
    return {"ratingKey": rk, "grandparentRatingKey": show_rk, "grandparentTitle": "?",
            "parentIndex": s, "index": e, "lastViewedAt": at, "viewCount": 1, "Guid": g, **kw}


class World:
    """One fake Plex server + Ryot V2, routed by URL. Records every request."""

    def __init__(self):
        self.sections = [
            {"key": "2", "type": "movie", "title": "Movies"},
            {"key": "4", "type": "show", "title": "Anime"},
            {"key": "5", "type": "artist", "title": "Music"},
            {"key": "1", "type": "show", "title": "TV Shows"},
        ]
        self.items = {"2": [], "4": [], "1": []}
        self.shows = {}
        self.entities = {}  # (slug, externalId) -> id
        self.episodes = []  # {id, externalId, show, season, episode}
        self.events = []  # {id, entityId, occurredAt}
        self.latest_plex = T0
        self.importable = True
        self.op_error = None
        self.requests = []
        self.ops = []
        self.fribb = FRIBB
        self.fribb_fetches = 0

    def __call__(self, req, timeout=None):
        self.requests.append(req)
        url = req.full_url
        if url.startswith(PLEX):
            return self.plex(req, url[len(PLEX):])
        if "anime-lists" in url:
            self.fribb_fetches += 1
            return FakeResponse(json.dumps(self.fribb).encode())
        path = urllib.parse.urlparse(url).path.removeprefix("/api")
        body = json.loads(req.data.decode()) if req.data else None
        return FakeResponse(json.dumps(self.ryot(req.get_method(), path, body)).encode())

    # Plex
    def plex(self, req, path):
        assert req.get_header("X-plex-token") == TOKEN
        if path == "/library/sections":
            mc = {"Directory": self.sections}
        elif path.startswith("/library/metadata/"):
            rk = path.split("/")[3].split("?")[0]
            mc = {"Metadata": [self.shows[rk]]}
        else:
            key = path.split("/")[3]
            since = int(path.split("lastViewedAt>>=")[1].split("&")[0])
            start = int(path.split("X-Plex-Container-Start=")[1].split("&")[0])
            hits = [i for i in self.items[key] if i.get("lastViewedAt", 0) >= since]
            mc = {"Metadata": hits[start : start + plex.PLEX_PAGE]}
        return FakeResponse(json.dumps({"MediaContainer": mc}).encode())

    # Ryot
    def ryot(self, method, path, body):
        if path == "/ryotql/execute":
            return {"data": {k: self.query(k, q) for k, q in body["queries"].items()}}
        if path == "/entity-providers/imports":
            return {"jobId": json.dumps([body["providerId"], body["externalId"]])}
        if path.startswith("/entity-providers/imports/"):
            provider, ext = json.loads(urllib.parse.unquote(path.rsplit("/", 1)[1]))
            if not self.importable:
                return {"status": "failed"}
            slug = {v: k for k, v in PROVIDERS.items()}[provider].split(".")[0]
            eid = f"new-{slug}-{ext}"
            self.entities[(slug, ext)] = eid
            return {"status": "completed", "data": {"id": eid}}
        if path.endswith("/operations/media-activity-log"):
            if self.op_error:
                raise self.op_error()
            assert body["idempotencyKey"] == body["payload"]["submissionId"]
            self.ops.append(body["payload"])
            return {"result": {"count": 1, "status": "saved"}}
        raise AssertionError(f"unexpected {method} {path}")

    def query(self, name, q):
        table = q["from"]["table"]
        preds = flatten(q["where"])
        if table == "sandboxProvider":
            items = [{"id": i, "slug": s} for s, i in PROVIDERS.items()]
        elif table == "event" and name == "m":
            items = [{"at": plex.ms_to_iso(self.latest_plex * 1000)}] if self.latest_plex else []
        elif table == "event":
            ids = set(preds["entityId"])
            items = [e for e in self.events if e["entityId"] in ids]
        elif q["from"]["alias"] == "ep":
            show, seasons = preds["sourceEntityId"][0], set(preds["seasonNumber"])
            items = [
                {"id": e["id"], "externalId": e["externalId"], "season": e["season"], "episode": e["episode"]}
                for e in self.episodes
                if e["show"] == show and e["season"] in seasons
            ]
        else:
            slug, exts = preds["entitySchemaSlug"][0], set(preds["externalId"])
            if slug == "show-episode":
                items = [
                    {"id": e["id"], "externalId": e["externalId"], "season": e["season"], "episode": e["episode"]}
                    for e in self.episodes
                    if e["externalId"] in exts
                ]
            else:
                items = [{"id": i, "externalId": x} for (s, x), i in self.entities.items() if s == slug and x in exts]
        return {"items": items, "pageInfo": {"hasMore": False, "nextCursor": None}}

    def plex_paths(self):
        return [r.full_url[len(PLEX):] for r in self.requests if r.full_url.startswith(PLEX)]


def flatten(where):
    """{field: [values]} out of the eq/in predicates of a RyotQL where."""
    out = {}
    for p in where.get("predicates", [where]):
        if p["type"] == "comparison" and p["right"].get("type") == "literal":
            out.setdefault(field(p["left"]), []).append(p["right"]["value"])
        elif p["type"] == "in":
            out.setdefault(field(p["expr"]), []).extend(v["value"] for v in p["values"])
    return out


def field(expr):
    while expr["type"] == "cast":
        expr = expr["expr"]
    return expr["path"][0] if expr["type"] == "jsonPath" else expr["field"]


def run(tmp_path, world, state=None, argv=(), env=None):
    if state is not None:
        (tmp_path / "plex-cursor.json").write_text(json.dumps(state))
    lines = []
    rc = plex.main(
        list(argv),
        env={
            "PLEX_SERVERS": f"{PLEX}|{TOKEN}",
            "RYOT_API_KEY": "key",
            "RYOT_URL": "http://ryot",
            "STATE_DIR": str(tmp_path),
            **(env or {}),
        },
        opener=world,
        sleep=lambda _s: None,
        now=lambda: 2_000_000_000,
        log=lines.append,
    )
    return rc, lines


def saved(tmp_path, name="plex-cursor.json"):
    return json.loads((tmp_path / name).read_text())


# ── config ────────────────────────────────────────────────────────────────────


def test_config_accepts_the_import_secret_name_and_skips_malformed_pairs():
    cfg = plex.Config.from_env(
        {"PLEX_IMPORT_SERVERS": "https://a:1/|ta, broken ,https://b:2|tb", "PLEX_ANIME_LIBRARIES": "Anime, Kids"}
    )
    assert cfg.servers == (("https://a:1", "ta"), ("https://b:2", "tb"))
    assert cfg.anime_libraries == {"Anime", "Kids"}


def test_config_with_no_env_has_no_servers():
    assert plex.Config.from_env({}).servers == ()


def test_main_refuses_to_start_without_servers_or_key(tmp_path):
    lines = []
    rc = plex.main([], env={"STATE_DIR": str(tmp_path)}, opener=World(), log=lines.append)
    assert rc == 1
    assert "RYOT_API_KEY" in lines[0] and "PLEX_SERVERS" in lines[0]


# ── Plex ──────────────────────────────────────────────────────────────────────


def test_only_scrobbled_views_count():
    assert plex.finished({"lastViewedAt": 5, "viewCount": 1})
    assert not plex.finished({"lastViewedAt": 5, "viewCount": 1, "viewOffset": 1000})
    assert not plex.finished({"lastViewedAt": 5, "viewOffset": 460547})
    assert not plex.finished({"viewCount": 2})


def test_the_token_travels_in_a_header_never_in_the_url(tmp_path):
    w = World()
    w.items["2"] = [movie("10", "Amélie", T0 + 60, 194)]
    w.entities[("movie", "194")] = "m1"
    run(tmp_path, w)
    assert all(TOKEN not in r.full_url for r in w.requests)


def test_viewed_since_pages_through_a_large_backlog(tmp_path):
    w = World()
    w.items["2"] = [movie(str(i), f"M{i}", T0 + 1 + i, i) for i in range(plex.PLEX_PAGE + 5)]
    items = plex.viewed_since((PLEX, TOKEN), "2", 1, T0, opener=w)
    assert len(items) == plex.PLEX_PAGE + 5


# ── anime mapping ─────────────────────────────────────────────────────────────


def test_compact_fribb_keeps_only_anilist_entries_with_a_tv_id():
    assert [r[0] for r in INDEX] == ["162147", "175035", "145139", "235", "779"]


def test_a_split_season_picks_the_part_by_episode_offset():
    # Pokémon Concierge: TMDB S1E1-4 = AniList 162147, S1E5-8 = 175035 eps 1-4.
    assert plex.map_anime(INDEX, "431703", "221301", 1, 4) == ("162147", 4)
    assert plex.map_anime(INDEX, "431703", "221301", 1, 5) == ("175035", 1)
    assert plex.map_anime(INDEX, "", "221301", 1, 8) == ("175035", 4)


def test_a_later_season_maps_to_its_own_entry():
    assert plex.map_anime(INDEX, "348545", "85937", 4, 1) == ("145139", 1)


def test_an_absolute_numbered_run_maps_only_season_one():
    assert plex.map_anime(INDEX, "72454", "30983", 1, 7) == ("235", 7)
    assert plex.map_anime(INDEX, "72454", "30983", 32, 1) is None
    assert plex.absolute_anime(INDEX, "72454", "") == "235"


def test_specials_and_ties_do_not_map():
    assert plex.map_anime(INDEX, "72454", "30983", 0, 1) is None
    tied = INDEX + [["999", "431703", "", {"tvdb": 1}, None]]
    assert plex.map_anime(tied, "431703", "", 1, 2) is None


def test_the_dataset_is_cached_and_refreshed_weekly(tmp_path):
    w = World()
    cfg = plex.Config(state_dir=str(tmp_path))
    plex.load_anime_index(cfg, 1000, opener=w)
    plex.load_anime_index(cfg, 1000 + plex.FRIBB_MAX_AGE - 1, opener=w)
    assert w.fribb_fetches == 1
    plex.load_anime_index(cfg, 1000 + plex.FRIBB_MAX_AGE, opener=w)
    assert w.fribb_fetches == 2


def test_a_failed_download_falls_back_to_the_stale_copy(tmp_path):
    cfg = plex.Config(state_dir=str(tmp_path))
    (tmp_path / "plex-anime-lists.json").write_text(json.dumps({"fetched_at": 0, "entries": INDEX}))

    def down(req, timeout=None):
        raise urllib.error.URLError("offline")

    lines = []
    assert plex.load_anime_index(cfg, 10**10, opener=down, log=lines.append) == INDEX
    assert "WARN" in lines[0]


# ── payloads + cursor ─────────────────────────────────────────────────────────


def view(**kw):
    base = dict(server=1, library="1/2", rating_key="10", at=1_790_000_060, title="T", kind="movie")
    return plex.View(**{**base, **kw})


def test_payload_shapes_per_kind():
    at = "2026-09-21T14:14:20.000Z"
    m = plex.activity_payload(view(), {"entity": "m1"})
    assert m == {
        "submissionId": "plex-1-10-1790000060",
        "submittedAt": at,
        "entry": {"kind": "complete", "entityId": "m1", "when": {"kind": "date", "finishedOn": at},
                  "consumedOn": "Plex"},
    }
    s = plex.activity_payload(view(kind="show"), {"show": "s1", "episode": "e1"})["entry"]
    assert s["kind"] == "episodes" and s["parentEntityId"] == "s1" and s["episodeEntityIds"] == ["e1"]
    a = plex.activity_payload(view(kind="anime", anime_episode=3), {"entity": "a1"})
    assert a["entry"] == {"kind": "progress", "entityId": "a1", "position": 3, "consumedOn": "Plex"}
    assert a["submittedAt"] == at  # = the progress event's occurredAt


def test_cursor_passes_every_done_view_but_stops_before_a_pending_one():
    vs = [view(rating_key="a", at=100), view(rating_key="b", at=200), view(rating_key="c", at=300)]
    ids = [v.submission_id for v in vs]
    assert plex.advance(50, vs, set(ids)) == 300
    assert plex.advance(50, vs, {ids[0], ids[2]}) == 199
    assert plex.advance(250, vs, {ids[0], ids[2]}) == 250
    assert plex.advance(50, [], set()) == 50


# ── main ──────────────────────────────────────────────────────────────────────


def full_world():
    w = World()
    w.items["2"] = [
        movie("10", "Amélie", T0 + 100, 194),
        movie("11", "Spirited Away", T0 + 200, 129),  # anime film: stays a movie
        movie("12", "Old", T0 - 50, 1),  # before the bootstrap cursor
        movie("13", "Half-watched", T0 + 250, 2, viewOffset=1000),
    ]
    w.items["1"] = [episode("20", "300", 3, 8, T0 + 300, tmdb_ep="5678354")]
    w.items["4"] = [episode("30", "400", 1, 5, T0 + 400)]
    w.shows = {
        "300": {"title": "INVINCIBLE", "Guid": [{"id": "tmdb://95557"}, {"id": "tvdb://368207"}]},
        "400": {"title": "Pokémon Concierge", "Guid": [{"id": "tvdb://431703"}, {"id": "tmdb://221301"}]},
    }
    w.entities[("movie", "194")] = "m-amelie"
    w.entities[("show", "95557")] = "s-inv"
    w.episodes = [{"id": "ep-inv-3-8", "externalId": "5678354", "show": "s-inv", "season": 3, "episode": 8}]
    return w


def test_first_run_starts_after_the_newest_plex_event_and_logs_each_kind(tmp_path):
    w = full_world()
    rc, lines = run(tmp_path, w)
    assert rc == 0
    entries = {o["submissionId"]: o["entry"] for o in w.ops}
    assert set(entries) == {
        f"plex-1-10-{T0 + 100}", f"plex-1-11-{T0 + 200}", f"plex-1-20-{T0 + 300}", f"plex-1-30-{T0 + 400}"
    }
    assert entries[f"plex-1-10-{T0 + 100}"]["entityId"] == "m-amelie"
    assert entries[f"plex-1-11-{T0 + 200}"] == {
        "kind": "complete", "entityId": "new-movie-129", "consumedOn": "Plex",
        "when": {"kind": "date", "finishedOn": plex.ms_to_iso((T0 + 200) * 1000)},
    }
    assert entries[f"plex-1-20-{T0 + 300}"]["episodeEntityIds"] == ["ep-inv-3-8"]
    assert entries[f"plex-1-30-{T0 + 400}"] == {
        "kind": "progress", "entityId": "new-anime-175035", "position": 1, "consumedOn": "Plex",
    }
    state = saved(tmp_path)
    assert state["start_at"] == T0
    assert state["cursors"] == {"1/2": T0 + 200, "1/4": T0 + 400, "1/1": T0 + 300}
    assert state["attempts"] == {}


def test_a_second_run_asks_plex_from_each_cursor_and_logs_nothing(tmp_path):
    w = full_world()
    run(tmp_path, w)
    w2 = full_world()
    w2.entities.update({("movie", "129"): "x", ("anime", "175035"): "y"})
    rc, lines = run(tmp_path, w2)
    assert rc == 0 and w2.ops == []
    assert any(f"/library/sections/2/all?type=1&lastViewedAt>>={T0 + 200}&" in p for p in w2.plex_paths())


def test_a_view_already_in_ryot_at_that_exact_second_is_not_relogged(tmp_path):
    w = full_world()
    w.events = [
        {"id": "v1", "entityId": "m-amelie", "occurredAt": plex.ms_to_iso((T0 + 100) * 1000)},
        {"id": "v2", "entityId": "ep-inv-3-8", "occurredAt": plex.ms_to_iso((T0 + 999) * 1000)},
    ]
    rc, lines = run(tmp_path, w)
    ids = [o["submissionId"] for o in w.ops]
    assert f"plex-1-10-{T0 + 100}" not in ids
    assert f"plex-1-20-{T0 + 300}" in ids  # same entity, another time: a rewatch
    assert "1 present" in lines[-1]


def test_an_unmappable_anime_episode_falls_back_to_the_tmdb_show(tmp_path):
    w = full_world()
    w.items = {"2": [], "1": [], "4": [episode("31", "500", 2, 1, T0 + 10, tmdb_ep="777")]}
    w.shows["500"] = {"title": "Unknown Anime", "Guid": [{"id": "tmdb://1234"}]}
    w.entities[("show", "1234")] = "s-unk"
    w.episodes = [{"id": "ep-unk", "externalId": "777", "show": "s-unk", "season": 2, "episode": 1}]
    rc, lines = run(tmp_path, w)
    assert w.ops[0]["entry"]["kind"] == "episodes"
    assert w.ops[0]["entry"]["parentEntityId"] == "s-unk"
    assert any("no AniList mapping for Unknown Anime S02E01" in l for l in lines)


def conan_world(tmdb_season):
    w = World()
    w.items["4"] = [episode("40", "600", 32, 1, T0 + 10, tmdb_ep="4940802")]
    w.shows["600"] = {"title": "Detective Conan", "Guid": [{"id": "tvdb://72454"}, {"id": "tmdb://30983"}]}
    w.entities[("show", "30983")] = "s-conan"
    w.episodes = [{"id": "ep-conan", "externalId": "4940802", "show": "s-conan", "season": tmdb_season,
                   "episode": 1109}]
    return w


def test_an_absolute_run_maps_through_the_tmdb_episode_number(tmp_path):
    w = conan_world(tmdb_season=1)
    rc, lines = run(tmp_path, w)
    assert w.ops[0]["entry"] == {
        "kind": "progress", "entityId": "new-anime-235", "position": 1109, "consumedOn": "Plex",
    }


def test_an_absolute_run_outside_tmdb_season_one_stays_on_the_show(tmp_path):
    w = conan_world(tmdb_season=32)
    rc, lines = run(tmp_path, w)
    assert w.ops[0]["entry"]["episodeEntityIds"] == ["ep-conan"]
    assert any("no AniList mapping" in l for l in lines)


def test_an_episode_found_only_by_number_is_logged(tmp_path):
    w = full_world()
    w.items = {"2": [], "4": [], "1": [episode("21", "300", 3, 8, T0 + 10)]}
    w.episodes[0]["externalId"] = "other"
    rc, _ = run(tmp_path, w)
    assert w.ops[0]["entry"]["episodeEntityIds"] == ["ep-inv-3-8"]


def test_a_failed_import_holds_the_cursor_and_retries_until_it_gives_up(tmp_path):
    w = full_world()
    w.importable = False
    rc, lines = run(tmp_path, w)
    assert rc == 1
    state = saved(tmp_path)
    assert state["cursors"]["1/2"] == T0 + 199  # Amélie logged, Spirited Away pending
    assert state["attempts"] == {f"plex-1-11-{T0 + 200}": 1, f"plex-1-30-{T0 + 400}": 1}
    for _ in range(plex.MAX_ATTEMPTS - 1):
        rc, lines = run(tmp_path, full_world_unimportable())
    state = saved(tmp_path)
    assert state["attempts"] == {}
    assert state["cursors"]["1/2"] == T0 + 200
    assert any("giving up on Spirited Away" in l for l in lines)


def full_world_unimportable():
    w = full_world()
    w.importable = False
    w.events = [{"id": "x", "entityId": "m-amelie", "occurredAt": plex.ms_to_iso((T0 + 100) * 1000)},
                {"id": "y", "entityId": "ep-inv-3-8", "occurredAt": plex.ms_to_iso((T0 + 300) * 1000)}]
    return w


def test_a_reused_key_with_another_target_counts_as_present(tmp_path):
    w = full_world()
    w.items = {"2": [movie("10", "Amélie", T0 + 100, 194)], "4": [], "1": []}
    body = '{"reason":{"diagnostics":[{"code":"operation-idempotency-conflict"}]}}'

    def conflict():
        return urllib.error.HTTPError("http://ryot", 400, "bad", {}, io.BytesIO(body.encode()))

    w.op_error = conflict
    rc, lines = run(tmp_path, w)
    assert rc == 0
    assert saved(tmp_path)["cursors"]["1/2"] == T0 + 100


def test_ryot_down_is_fatal_and_keeps_the_old_cursor(tmp_path):
    w = full_world()

    def boom():
        return urllib.error.HTTPError("http://ryot", 500, "err", {}, io.BytesIO(b"oops"))

    w.op_error = boom
    state = {"start_at": T0, "cursors": {"1/2": T0}}
    rc, lines = run(tmp_path, w, state=state)
    assert rc == 1
    assert saved(tmp_path)["cursors"] == {"1/2": T0}


def test_dry_run_writes_imports_and_saves_nothing(tmp_path):
    w = full_world()
    rc, lines = run(tmp_path, w, argv=["--dry-run"])
    assert rc == 0
    assert w.ops == []
    assert not [r for r in w.requests if "/entity-providers/imports" in r.full_url]
    assert not (tmp_path / "plex-cursor.json").exists()
    assert any(l.startswith("would log movie: Amélie") for l in lines)
    assert any(l.startswith("would import + log movie Spirited Away") for l in lines)
