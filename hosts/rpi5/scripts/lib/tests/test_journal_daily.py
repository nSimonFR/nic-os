import json
from datetime import date

import pytest

from conftest import FakeOpener, json_reply
from nicos_scripts.connectors import journal_daily as wm

SEP = "\x1f"
W1 = "11111111-1111-1111-1111-111111111111"
W2 = "22222222-2222-2222-2222-222222222222"
# 2026-10-19 08:13 and 18:31 Europe/Paris
T1, T2 = 1792390421, 1792427478


class FakePg:
    """Answers psql_rows by matching on the SQL text."""

    def __init__(self, workouts, points, place=None, areas=(("75013", "Paris"),), tracks=(), music=(), games=(), activity=(),
                 flights=(), screens=(), rides=(), steps=(), v1_games=(), v1_artists=()):
        self.workouts, self.points, self.place, self.areas = workouts, points, place, areas
        self.flights, self.screens, self.rides, self.steps = flights, screens, rides, steps
        self.v1_games, self.v1_artists = v1_games, v1_artists
        self.tracks, self.music, self.games, self.activity = tracks, music, games, activity
        self.sql = []

    def __call__(self, cmd):
        sql = cmd[cmd.index("-c") + 1]
        self.sql.append(sql)
        if "oc_calendarobjects" in sql:
            rows = []
        elif "FROM flight f" in sql:
            rows = self.flights
        elif "-- ride history" in sql:
            rows = self.rides
        elif "-- step history" in sql:
            rows = self.steps
        elif "FROM workouts" in sql:
            rows = self.workouts
        elif "FROM health_metrics" in sql:
            rows = self.activity
        elif "FROM seen" in sql:
            rows = self.v1_games
        elif "FROM metadata m" in sql:
            rows = self.v1_artists
        elif "'video-game'" in sql:
            rows = self.games
        elif "'music'" in sql:
            rows = self.music
        elif "'movie'" in sql:
            rows = self.screens
        elif "FROM tracks" in sql:
            rows = self.tracks
        elif "FROM users" in sql:
            rows = [("1",)]
        elif "FROM places" in sql:
            rows = [self.place] if self.place else []
        elif "geodata" in sql:
            rows = list(self.areas)
        elif "FROM points" in sql:
            rows = self.points
        else:
            raise AssertionError(sql)
        return "\n".join(SEP.join(str(v) for v in r) for r in rows)


def ride(wid, start, km=9.5, minutes=37):
    return (wid, "Cycling", start, start + minutes * 60, km * 1000, minutes * 60, 300)


LO19 = 1792375200  # 2026-10-19 04:00 Europe/Paris


def play(title, artist, seconds, h=1, track="t"):
    """A Ryot V11 music row, `h` hours into Oct 19."""
    return (title, artist, seconds, LO19 + h * 3600, track)


def game(title, seconds):
    """A Ryot V11 playtime push for Oct 19 (04:50 the next morning)."""
    return (LO19 + 86400 + 3000, title, seconds)


def cfg(tmp_path, **kw):
    base = dict(state_path=str(tmp_path / "state.json"), dry_run=False, day="2026-10-19",
                arkose_sessions=str(tmp_path / "no-arkose.json"))  # never the host's real files
    base.update(kw)
    return wm.Config(**base)


def memos_opener():
    return FakeOpener([
        json_reply({"name": "attachments/A"}),
        json_reply({"name": "memos/M"}),
        json_reply({"name": "memos/M"}),
    ])


def no_render(tracks, path):
    open(path, "wb").write(b"PNG")


def run_day(c, pg, op, state):
    return wm.journal_day(c, pg, wm.Memos("http://m", "TOKEN", op), state,
                          date(2026, 10, 19), 1, lambda m: None, no_render, str(c.state_path).rsplit("/", 1)[0])


def test_config_defaults_to_dry_run():
    assert wm.Config.from_env({}).dry_run is True


def test_target_days_ends_yesterday():
    c = wm.Config(days=2)
    assert wm.target_days(c, today=date(2026, 10, 25)) == [date(2026, 10, 23), date(2026, 10, 24)]


def test_arrondissement_and_city_fallback():
    assert wm.arrondissement("75013", "Paris") == "Paris 13e"
    assert wm.arrondissement("75001", "Paris") == "Paris 1er"
    assert wm.arrondissement("93400", "Saint-Ouen-sur-Seine") == "Saint-Ouen"


def test_content_names_places_and_tags_a_commute():
    ws = [wm.Workout(W1, "Cycling", T1, T1 + 2220, 9.5, 37, 300),
          wm.Workout(W2, "Cycling", T2, T2 + 2700, 9.8, 45, 312)]
    home, work = wm.Place("🏡 Home", "Home"), wm.Place("💼 Work", "Work")
    text = wm.content("2026-10-19", ws, [(home, work), (work, home)], "https://d")
    assert text.startswith("### 🚲 Vélo - 2 trajets · 19,3 km · 1 h 22 · 612 kcal\n\n")
    assert "- **08:13** 🏡 Home → 💼 Work · 9,5 km · 37 min · 15,4 km/h" in text
    assert "date=2026-10-19" in text
    assert text.rstrip().endswith("#bike #commute")


def test_content_mixed_kinds_prefixes_each_line():
    ws = [wm.Workout(W1, "Cycling", T1, T1 + 600, 3, 10, 0),
          wm.Workout(W2, "Running", T2, T2 + 1800, 5, 30, 0)]
    text = wm.content("2026-10-19", ws, [None, None], "https://d")
    assert text.startswith("### 🏅 Sport - 2 séances · 8,0 km · 40 min")
    assert "- 🏃 **18:31** Course" in text
    assert text.rstrip().endswith("#bike #run")


def test_posts_one_memo_dated_at_the_last_workout_end(tmp_path):
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")])
    op, state = memos_opener(), {}
    assert run_day(cfg(tmp_path), pg, op, state) == "memos/M"
    att, memo, patch = (op.body_of(i) for i in range(3))
    assert att["filename"] == "map-2026-10-19.jpg"
    assert memo["visibility"] == "PRIVATE" and memo["attachments"] == [{"name": "attachments/A"}]
    assert memo["location"]["latitude"] == 48.91
    assert op.requests[2].full_url.endswith("/memos/M?updateMask=create_time")
    assert patch == {"createTime": "2026-10-19T06:50:41Z"}
    assert op.requests[0].headers["Authorization"] == "Bearer TOKEN"
    assert state["2026-10-19"]["memo"] == "memos/M"


def test_unchanged_day_is_skipped(tmp_path):
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")])
    state = {}
    run_day(cfg(tmp_path), pg, memos_opener(), state)
    op = memos_opener()
    assert run_day(cfg(tmp_path), pg, op, state) == "memos/M"
    assert op.requests == []


def update_opener(memo):
    """Replies for: upload the map, GET the memo, set attachments, update."""
    return FakeOpener([json_reply({"name": "attachments/NEW"}), json_reply(memo),
                       json_reply({}), json_reply({"name": memo.get("name", "")})])


def test_changed_day_is_updated_in_place_keeping_user_additions(tmp_path):
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")])
    state = {"2026-10-19": {"memo": "memos/OLD", "sig": "stale",
                            "text": "OLD BLOCK\n", "atts": ["attachments/OLDMAP"]}}
    op = update_opener({"name": "memos/OLD", "content": "Great day!\n\nOLD BLOCK\nPS: rain",
                        "attachments": [{"name": "attachments/OLDMAP"}, {"name": "attachments/MINE"}]})
    assert run_day(cfg(tmp_path), pg, op, state) == "memos/OLD"
    calls = [(r.get_method(), r.full_url.rsplit("/v1", 1)[-1]) for r in op.requests]
    assert [c[0] for c in calls] == ["POST", "GET", "PATCH", "PATCH"]
    assert calls[2][1] == "/memos/OLD/attachments"
    assert op.body_of(2)["attachments"] == [{"name": "attachments/NEW"}, {"name": "attachments/MINE"}]
    assert calls[3][1] == "/memos/OLD?updateMask=content,create_time,location"
    new = op.body_of(3)["content"]
    assert new.startswith("Great day!\n\n### 🚲 Vélo") and new.endswith("#bike\nPS: rain")
    assert state["2026-10-19"]["text"] in new and state["2026-10-19"]["atts"] == ["attachments/NEW"]


def test_a_hand_rewritten_block_keeps_the_users_text(tmp_path):
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")])
    state = {"2026-10-19": {"memo": "memos/OLD", "sig": "stale", "text": "OLD BLOCK\n", "atts": []}}
    op = update_opener({"name": "memos/OLD", "content": "my own words", "attachments": []})
    lines = []
    wm.journal_day(cfg(tmp_path), pg, wm.Memos("http://m", "T", op), state, date(2026, 10, 19), 1,
                   lines.append, no_render, str(tmp_path))
    assert op.body_of(3)["content"] == "my own words"
    assert "edited by hand" in lines[0]


def test_a_memo_deleted_in_memos_is_recreated(tmp_path):
    import urllib.error

    def gone():
        raise urllib.error.HTTPError("u", 404, "gone", {}, None)

    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")])
    state = {"2026-10-19": {"memo": "memos/OLD", "sig": "stale", "text": "x", "atts": []}}
    op = FakeOpener([json_reply({"name": "attachments/A"}), gone,
                     json_reply({"name": "memos/M"}), json_reply({"name": "memos/M"})])
    assert run_day(cfg(tmp_path), pg, op, state) == "memos/M"


def test_day_without_workouts_posts_nothing(tmp_path):
    op = memos_opener()
    assert run_day(cfg(tmp_path), FakePg([], []), op, {}) is None
    assert op.requests == []


def test_dry_run_posts_nothing(tmp_path):
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")])
    op, state = memos_opener(), {}
    run_day(cfg(tmp_path, dry_run=True), pg, op, state)
    assert op.requests == [] and state == {}


def test_place_labels_from_dawarich_tags_and_names(tmp_path):
    at = lambda row: wm.place(cfg(tmp_path), FakePg([], [], place=row), 1, 48.83, 2.34)
    # geocoder-named place tagged Work reads as its tag
    assert at(("93400 Rue Godillot 5 ()", "1", "Work", "💼")) == wm.Place("💼 Work", "Work")
    # hand-named place keeps its name, with the tag's icon
    assert at(("Maman", "0", "Home", "🏡")) == wm.Place("🏡 Maman", "Home")
    assert at(("Fitness Park", "0", "", "")) == wm.Place("Fitness Park")
    pg = FakePg([], [])
    assert wm.place(cfg(tmp_path), pg, 1, 48.83, 2.34) == wm.Place("Paris 13e")
    sql = next(s for s in pg.sql if "FROM places" in s)
    assert "p.source = 0 OR t.id IS NOT NULL" in sql and ", 300)" in sql
    assert "ORDER BY t.id IS NULL" in sql


class FakeImmich:
    admin_key = "ADMIN"

    def __init__(self, assets=(), fail=False, past=()):
        self.assets, self.fail, self.previews, self.past = list(assets), fail, [], list(past)

    def day(self, day):
        if self.fail:
            raise OSError("connection refused")
        return self.assets

    def memories(self, day):
        if self.fail:
            raise OSError("connection refused")
        return self.past

    def preview(self, asset_id):
        self.previews.append(asset_id)
        return b"JPG"

    def link(self, asset_id):
        return f"https://immich/photos/{asset_id}"

    def search_link(self, lo, hi):
        return f"https://immich/search?{lo}-{hi}"

    def memory_link(self, memory_id):
        return f"https://immich/memories/{memory_id}"

    def city(self, asset_id):
        return "Brest"


def photo(n, fav=False, gps=True):
    exif = {"latitude": 48.85, "longitude": 2.35, "city": "Paris"} if gps else {}
    return {"id": f"p{n}", "fileCreatedAt": f"2026-10-19T{10 + n:02d}:00:00.000Z",
            "isFavorite": fav, "exifInfo": exif}


def test_pick_photos_one_per_moment_favourite_first():
    assets = [photo(n) for n in range(10)]  # one an hour: every pause equal
    assets[7]["isFavorite"] = True
    picks = wm.pick_photos(assets, 3)
    assert [(p["id"], p["burst"]) for p in picks] == [("p1", 2), ("p3", 3), ("p7", 5)]  # p7: the favourite
    assert [a["id"] for a in wm.pick_photos(assets[:2], 6)] == ["p0", "p1"]
    assert wm.pick_photos(assets, 0) == []


def test_groups_cut_at_the_longest_pauses():
    t = lambda h, m, s=0: {"id": f"{h}{m}{s}", "fileCreatedAt": f"2026-04-30T{h:02d}:{m:02d}:{s:02d}Z"}
    # morning airport (3 shots), a long Rome afternoon of shots ~5 min apart, one at night
    day = [t(6, 45), t(6, 54), t(7, 4)] + [t(10 + i // 12, (i * 5) % 60) for i in range(60)] + [t(20, 13)]
    gs = wm.groups(day, 9)
    assert len(gs) == 9 and sum(map(len, gs)) == len(day)
    assert gs[-1] == [day[-1]]  # the night shot stays alone
    assert len(wm.groups(day[:3], 9)) == 3 and wm.groups([], 9) == []
    burst = [t(12, 29, s) for s in range(7)]
    assert len(wm.groups(burst, 9)) == 1  # a burst is never split


def test_workout_day_attaches_map_then_photos(tmp_path):
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")])
    im = FakeImmich([photo(1), photo(2)])
    op = FakeOpener([json_reply({"name": "attachments/MAP"}), json_reply({"name": "attachments/COL"}),
                     json_reply({"name": "memos/M"}), json_reply({"name": "memos/M"})])
    collages = []
    wm.journal_day(cfg(tmp_path), pg, wm.Memos("http://m", "T", op), {}, date(2026, 10, 19), 1,
                   lambda m: None, no_render, str(tmp_path), im,
                   collage_fn=lambda imgs, labels, path: (collages.append(labels), no_render(None, path)))
    assert [op.body_of(i)["filename"] for i in range(2)] == ["map-2026-10-19.jpg", "photos-2026-10-19.jpg"]
    assert collages == [[("13:00", 1), ("14:00", 1)]] and im.previews == ["p1", "p2"]
    memo = op.body_of(2)
    assert [a["name"] for a in memo["attachments"]] == ["attachments/MAP", "attachments/COL"]
    assert memo["content"].startswith("### 📷 Photos - 2\n\n- [13:00](https://immich/photos/p1) · Paris 13e\n"
                                      "- [14:00](https://immich/photos/p2) · Paris 13e\n\n### 🚲 Vélo")
    assert memo["content"].rstrip().endswith("#photos #bike")


def test_photo_only_day_is_dated_and_pinned_by_the_last_photo(tmp_path):
    im = FakeImmich([photo(1), photo(3, gps=False)])
    op = FakeOpener([json_reply({"name": "attachments/COL"}),
                     json_reply({"name": "memos/M"}), json_reply({"name": "memos/M"})])
    wm.journal_day(cfg(tmp_path), FakePg([], []), wm.Memos("http://m", "T", op), {},
                   date(2026, 10, 19), 1, lambda m: None, no_render, str(tmp_path), im,
                   collage_fn=lambda imgs, labels, path: no_render(None, path))
    memo = op.body_of(1)
    assert memo["content"].startswith("### 📷 Photos - 2\n\n- [13:00](https://immich/photos/p1) · Paris 13e\n- [15:00](https://immich/photos/p3)\n")
    assert memo["location"]["placeholder"] == "Paris"
    assert op.body_of(2) == {"createTime": "2026-10-19T13:00:00.000Z"}


def test_memories_section_links_each_immich_memory(tmp_path):
    old = lambda y, n, **kw: {**photo(n, **kw), "id": f"y{y}-{n}",
                              "fileCreatedAt": f"{y}-10-19T{10 + n:02d}:00:00.000Z"}
    past = [(2023, [old(2023, 1), old(2023, 2, gps=False)], "M23"), (2010, [old(2010, 1, gps=False)], "M10")]
    im = FakeImmich([photo(1)], past=past)
    op = FakeOpener([json_reply({"name": "attachments/COL"}),
                     json_reply({"name": "memos/M"}), json_reply({"name": "memos/M"})])
    wm.journal_day(cfg(tmp_path), FakePg([], []), wm.Memos("http://m", "T", op), {},
                   date(2026, 10, 19), 1, lambda m: None, no_render, str(tmp_path), im,
                   collage_fn=lambda imgs, labels, path: no_render(None, path))
    assert op.body_of(0)["filename"] == "photos-2026-10-19.jpg"  # no memories collage
    assert ("### 🕰 Souvenirs\n\n- [Il y a 3 ans · 2023](https://immich/memories/M23) · Paris · 2 photos\n"
            "- [Il y a 16 ans · 2010](https://immich/memories/M10) · Brest · 1 photo\n\n") in op.body_of(1)["content"]


def test_immich_memories_api_drops_screenshots_and_other_types():
    shot = {"id": "s", "originalFileName": "IMG_1.PNG", "exifInfo": {}}
    pic = {"id": "c", "originalFileName": "IMG_2.HEIC", "exifInfo": {"make": "Apple"}}
    reply = [{"id": "A", "type": "on_this_day", "data": {"year": 2021}, "assets": [shot]},
             {"id": "B", "type": "on_this_day", "data": {"year": 2022}, "assets": [pic, shot]},
             {"id": "C", "type": "birthday", "data": {"year": 2020}, "assets": [pic]}]
    op = FakeOpener([json_reply(reply), json_reply({})])
    im = wm.Immich("https://im", "k", op, admin_key="ADMIN")
    got = im.memories(date(2026, 10, 12))
    assert [(y, [a["id"] for a in m], i) for y, m, i in got] == [(2022, ["c"], "B")]
    assert op.requests[0].full_url == "https://im/api/memories?for=2026-10-12"
    assert op.requests[0].get_header("X-api-key") == "ADMIN"
    assert im.memory_link("B") == "https://im/memories/B"


def test_immich_search_link_is_a_date_range_query():
    import urllib.parse
    url = wm.Immich("https://im", "k").search_link(1792980000, 1793066400)
    assert url.startswith("https://im/search?query=")
    q = json.loads(urllib.parse.unquote(url.split("query=")[1]))
    assert q == {"takenAfter": "2026-10-26T02:00:00.000Z", "takenBefore": "2026-10-27T01:59:59.000Z"}


def test_immich_down_still_writes_the_workouts(tmp_path):
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")])
    lines = []
    name = wm.journal_day(cfg(tmp_path), pg, wm.Memos("http://m", "T", memos_opener()), {},
                          date(2026, 10, 19), 1, lines.append, no_render, str(tmp_path),
                          FakeImmich(fail=True))
    assert name == "memos/M" and "Immich unavailable" in lines[0]


def test_new_photo_changes_the_signature():
    ws = [wm.Workout(W1, "Cycling", T1, T1 + 60, 1, 1, 0)]
    assert wm.signature(ws, [2], ["p1"]) != wm.signature(ws, [2], ["p1", "p2"])


def test_pick_photos_one_slot_per_burst():
    burst = [{"id": f"b{i}", "fileCreatedAt": f"2026-10-19T12:29:{i:02d}Z"} for i in range(7)]
    day = [{"id": "m", "fileCreatedAt": "2026-10-19T07:34:00Z"}, *burst,
           {"id": "e", "fileCreatedAt": "2026-10-19T15:57:00Z"}]
    picks = wm.pick_photos(day, 9)
    assert [a["id"] for a in picks] == ["m", "b3", "e"]
    assert [wm.tile_label(a) for a in picks] == [("09:34", 1), ("14:29", 7), ("17:57", 1)]
    day[5]["isFavorite"] = True
    assert [a["id"] for a in wm.pick_photos(day, 9)] == ["m", "b4", "e"]


def test_a_loop_reads_around_its_place():
    ws = [wm.Workout(W1, "Cycling", T1, T1 + 420, 2.3, 7, 50)]
    p13 = wm.Place("Paris 13e")
    assert "- **08:13** autour de Paris 13e · 2,3 km" in wm.content("2026-10-19", ws, [(p13, p13)], "d")


def test_collage_grid():
    assert [wm.collage_grid(n) for n in (1, 3, 4, 5, 6, 7, 9)] == \
        [(1, 1), (3, 1), (2, 2), (3, 2), (3, 2), (3, 3), (3, 3)]


def test_render_collage_makes_one_labelled_sheet(tmp_path):
    import io

    from PIL import Image

    def jpeg(color, size):
        buf = io.BytesIO()
        Image.new("RGB", size, color).save(buf, "JPEG")
        return buf.getvalue()

    out = tmp_path / "c.jpg"
    wm.render_collage([jpeg("red", (300, 200)), jpeg("blue", (200, 300)), jpeg("green", (100, 100)),
                       jpeg("white", (400, 400))], [("08:12", 1), ("12:31", 1), ("14:29", 8), ("17:57", 1)],
                      str(out), tile=100, gap=4)
    sheet = Image.open(out)
    assert sheet.size == (204, 204)
    assert sheet.getpixel((50, 10))[0] > 200            # top-left tile is red
    assert sheet.getpixel((150, 10))[2] > 200           # top-right tile is blue
    assert sheet.getpixel((8, 92)) != sheet.getpixel((50, 10))  # label box drawn


def test_day_runs_from_4am_to_4am():
    lo, hi = wm.day_bounds(date(2026, 10, 19))
    assert lo == 1792375200 and hi - lo == 86400   # 2026-10-19 04:00 CEST
    lo, hi = wm.day_bounds(date(2026, 10, 24))      # spans the Oct 25 03:00 DST end: 25 h
    assert hi - lo == 25 * 3600


def test_map_follows_the_route_shape():
    north_south = [[(48.83, 2.34), (48.91, 2.34)]]
    assert wm.map_size(north_south) == (750, 1000)
    east_west = [[(48.83, 2.34), (48.83, 2.37)]]
    assert wm.map_size(east_west) == (1000, 750)


def test_media_metadata_is_paris_wall_time_with_offset():
    meta = wm.media_metadata(b"not an image", 1792390421, location=(48.9, 2.33),
                             camera=("Apple", "iPhone 11 Pro"))
    assert meta == {"photo": {"captureTime": {"localDateTime": "2026-10-19T08:13:41", "utcOffset": "+02:00"},
                              "location": {"latitude": 48.9, "longitude": 2.33},
                              "cameraMake": "Apple", "cameraModel": "iPhone 11 Pro"}}
    winter = wm.media_metadata(b"", 1793000000)["photo"]["captureTime"]
    assert winter["utcOffset"] == "+01:00"


def test_media_metadata_reads_the_image_size():
    import io

    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (30, 20)).save(buf, "JPEG")
    meta = wm.media_metadata(buf.getvalue(), 1792390421)
    assert (meta["width"], meta["height"]) == (30, 20)


def test_map_and_collage_carry_metadata(tmp_path):
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")])
    p1, p2 = photo(1), photo(2, gps=False)
    for p in (p1, p2):
        p["exifInfo"].update({"make": "Apple", "model": "iPhone 11 Pro"})
    op = FakeOpener([json_reply({"name": "attachments/MAP"}), json_reply({"name": "attachments/COL"}),
                     json_reply({"name": "memos/M"}), json_reply({"name": "memos/M"})])
    wm.journal_day(cfg(tmp_path), pg, wm.Memos("http://m", "T", op), {}, date(2026, 10, 19), 1,
                   lambda m: None, no_render, str(tmp_path), FakeImmich([p1, p2]),
                   collage_fn=lambda imgs, labels, path: no_render(None, path))
    map_meta, col_meta = op.body_of(0)["mediaMetadata"]["photo"], op.body_of(1)["mediaMetadata"]["photo"]
    assert map_meta["location"] == {"latitude": 48.91, "longitude": 2.33}
    assert map_meta["captureTime"]["localDateTime"] == "2026-10-19T08:50:41"
    assert col_meta["captureTime"]["localDateTime"] == "2026-10-19T14:00:00"
    assert col_meta["location"] == {"latitude": 48.85, "longitude": 2.35}  # p2 has none
    assert (col_meta["cameraMake"], col_meta["cameraModel"]) == ("Apple", "iPhone 11 Pro")


def test_photo_lines_one_per_moment():
    assert wm.photo_lines([("09:34", "u1", "", 1), ("14:29", "u2", "🏡 Alfie", 8)]) == \
        ["- [09:34](u1)", "- [14:29](u2) · 🏡 Alfie · 8 photos"]


def test_content_puts_weather_and_agenda_first_work_last():
    ws = [wm.Workout(W1, "Cycling", T1, T1 + 600, 3, 10, 0)]
    text = wm.content("2026-10-19", ws, [None], "d", weather="🌧 Pluie légère · 6-13 °C",
                      agenda=["- **19:00-21:00** Dinner"], work=(4, 135, 14))
    assert text.startswith("🌧 Pluie légère · 6-13 °C\n\n### 📅 Agenda\n\n- **19:00-21:00** Dinner\n\n"
                           "### 🚲 Vélo")
    assert text.endswith("\n\n### 💼 Travail - 4 réunions (2h15) 14 personnes\n\n___________\n\n#bike #work\n")
    assert "### 💼 Travail - 1 réunion (45min) 1 personne" in wm.content("d", [], [], "d", work=(1, 45, 1))


def test_weather_alone_makes_no_entry(tmp_path):
    op = memos_opener()
    assert wm.journal_day(cfg(tmp_path), FakePg([], []), wm.Memos("http://m", "T", op), {},
                          date(2026, 10, 19), 1, lambda m: None, no_render, str(tmp_path),
                          weather_fn=lambda d, lat, lon: "☀️ Clear") is None
    assert op.requests == []


def test_weather_uses_the_first_ride_start(tmp_path):
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")])
    asked = []
    wm.journal_day(cfg(tmp_path, dry_run=True), pg, wm.Memos("http://m", "T", memos_opener()), {},
                   date(2026, 10, 19), 1, lambda m: None, no_render, str(tmp_path),
                   weather_fn=lambda d, lat, lon: asked.append((lat, lon)) or "☀️ Clear")
    assert asked == [(48.83, 2.34)]


def trk(tid, start, minutes, km, mode, *pts):
    path = json.dumps({"type": "LineString", "coordinates": [[lon, lat] for lat, lon in pts]})
    return (tid, start, start + minutes * 60, km * 1000, minutes * 60, mode, path)


def test_map_draws_every_trip_coloured_by_mode():
    ride_w = wm.Workout(W1, "Cycling", T1, T1 + 2220, 9.5, 37, 300)
    late = wm.Workout(W2, "Cycling", T2, T2 + 600, 2, 10, 0)
    # Dawarich called the ride a run (3); the car trip has no workout
    by_ride = wm.Trip("1", T1 - 60, T1 + 2300, 9.4, 39, 3, ((48.83, 2.34), (48.91, 2.33)))
    car = wm.Trip("2", T1 + 7200, T1 + 9000, 13.9, 30, 5, ((48.91, 2.33), (48.85, 2.30)))
    lines = wm.map_lines([ride_w, late], [[(1, 1), (2, 2)], [(3, 3), (4, 4)]], [by_ride, car])
    assert [c for _, c in lines] == [wm.COLORS[0], wm.ROAD, wm.COLORS[0]]
    assert lines[2][0] == [(3, 3), (4, 4)]  # no trip yet: the workout's own points
    assert wm.other_trips([ride_w, late], [by_ride, car]) == [car]


def test_trip_only_day_gets_an_entry_with_its_trips(tmp_path):
    pg = FakePg([], [], tracks=[trk("7", T1, 35, 13.9, 5, (48.83, 2.36), (48.85, 2.30)),
                                trk("8", T2, 2, 0.3, 0, (48.85, 2.30), (48.85, 2.31))])
    op, rendered = memos_opener(), []
    wm.journal_day(cfg(tmp_path), pg, wm.Memos("http://m", "T", op), {}, date(2026, 10, 19), 1,
                   lambda m: None, lambda lines, path: (rendered.append(lines), no_render(None, path)),
                   str(tmp_path))
    memo = op.body_of(1)
    assert memo["content"].startswith("### 🧭 Déplacements - 2 trajets · 14,2 km\n\n"
                                      "- **08:13** 🚗 autour de Paris 13e · 13,9 km · 35 min\n"
                                      "- **18:31** 🧭 autour de Paris 13e · 0,3 km · 2 min\n\n"
                                      "[Voir la journée dans Dawarich]")
    assert [c for _, c in rendered[0]] == [wm.ROAD, wm.OTHER]
    assert op.body_of(2) == {"createTime": "2026-10-19T16:33:18Z"}
    sql = next(s for s in pg.sql if "FROM tracks" in s)
    assert ">= 300" in sql and "<> 1" in sql


def test_music_section_sits_between_photos_and_work(tmp_path):
    plays = [play("Club", "Lomepal", 250), play("Starlight", "Muse", 240), play("Trop beau", "Lomepal", 244),
             play("Un peu de sang", "Lomepal", 305)]
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")], music=plays)
    op = memos_opener()
    wm.journal_day(cfg(tmp_path), pg, wm.Memos("http://m", "T", op), {}, date(2026, 10, 19), 1,
                   lambda m: None, no_render, str(tmp_path))
    text = op.body_of(1)["content"]
    assert ("\n\n### 🎵 Musique - 4 titres · 17 min\n\n"
            "- **Lomepal** · Club, Trop beau, Un peu de sang\n- **Muse** · Starlight\n\n___________\n\n#bike #music\n") in text


def test_music_alone_makes_no_entry(tmp_path):
    op = memos_opener()
    pg = FakePg([], [], music=[play("Club", "Lomepal", 250)])
    assert wm.journal_day(cfg(tmp_path), pg, wm.Memos("http://m", "T", op), {},
                          date(2026, 10, 19), 1, lambda m: None, no_render, str(tmp_path)) is None


SESSION = {"_id": "s1", "startDate": "2026-10-19T10:16:17+00:00", "gymName": "Arkose Chevaleret",
           "tops": 7, "flashs": 0, "tried": 1, "retops": 1, "climbedHeight": 38, "isEmpty": False,
           "topsCountsByLabel": {"5": 2, "4": 5}, "gymLabels": {"4": "vert", "5": "bleu"},
           "sessionLevel": {"label": 4}, "isLevelUp": True}


def test_climbing_day_gets_an_entry_with_its_section(tmp_path):
    store = tmp_path / "sessions.json"
    other = {**SESSION, "_id": "s0", "startDate": "2026-10-18T10:00:00+00:00"}
    store.write_text(json.dumps({"sessions": {"s1": SESSION, "s0": other}}))
    op = memos_opener()
    wm.journal_day(cfg(tmp_path, arkose_sessions=str(store)), FakePg([], []), wm.Memos("http://m", "T", op),
                   {}, date(2026, 10, 19), 1, lambda m: None, no_render, str(tmp_path))
    assert op.body_of(0)["content"] == (
        "### 🧗 Escalade - Arkose Chevaleret · 7 tops · 38 m\n\n"
        "- 🔵 **Bleu**: 2\n- 🟢 **Vert**: 5\n- **Retops**: 1\n- **Non topés**: 1\n- **Niveau**: vert ⬆️"
        "\n\n___________\n\n#climbing\n")
    assert op.body_of(1) == {"createTime": "2026-10-19T10:16:17+00:00"}


def test_arkose_store_missing_is_silent_corrupt_is_logged(tmp_path):
    lines = []
    assert wm.day_climbing(cfg(tmp_path, arkose_sessions=str(tmp_path / "nope.json")),
                           date(2026, 10, 19), lines.append) == []
    assert lines == []
    (tmp_path / "bad.json").write_text("{")
    assert wm.day_climbing(cfg(tmp_path, arkose_sessions=str(tmp_path / "bad.json")),
                           date(2026, 10, 19), lines.append) == []
    assert "climbing unavailable" in lines[0]


def test_climbing_mosaic_tops_then_retops_then_unsent(tmp_path):
    def b(bid, label, share):
        return {"_id": bid, "label": label, "picture": {"id": "i" + bid, "share": share}}
    sess = {**SESSION, "boulders": [b("g1", 4, "S1"), b("b1", 5, "S2") | {"flashed": True},
                                    b("np", 4, None) | {"picture": {}}],
            "retopBoulders": [b("g2", 4, None) | {"flashed": True}],  # the first send's flash
            "triedBoulders": [b("t", 5, "ST")]}
    store = tmp_path / "sessions.json"
    store.write_text(json.dumps({"sessions": {"s1": sess}}))
    op = FakeOpener([json_reply({"name": "attachments/C"}), json_reply({"name": "memos/M"}),
                     json_reply({"name": "memos/M"})])
    fetched, mosaics = [], []

    def fetch(url):
        fetched.append(url)
        if url.endswith("S1.jpg"):
            raise OSError("404")
        return b"JPG"
    lines = []
    wm.journal_day(cfg(tmp_path, arkose_sessions=str(store)), FakePg([], []), wm.Memos("http://m", "T", op),
                   {}, date(2026, 10, 19), 1, lines.append, no_render, str(tmp_path),
                   collage_fn=lambda imgs, labels, path: (mosaics.append(labels), no_render(None, path)),
                   fetch_fn=fetch)
    s3 = "https://socialboulder.s3-eu-west-1.amazonaws.com"
    assert fetched == [f"{s3}/boulderPicsShare/S2.jpg", f"{s3}/boulderPicsShare/S1.jpg",
                       f"{s3}/800/bouldersPics/ig2.jpg", f"{s3}/boulderPicsShare/ST.jpg"]
    assert mosaics == [[("bleu", 1, "flash"), ("vert", 1, "retop"), ("bleu", 1, "tried")]]
    assert op.body_of(0)["filename"] == "climbing-2026-10-19.jpg"
    assert "boulder picture unavailable" in lines[0]


def test_collage_marks_flash_gold_and_unsent_grey(tmp_path):
    import io

    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (100, 100), (0, 0, 255)).save(buf, "JPEG")
    out = tmp_path / "c.jpg"
    wm.render_collage([buf.getvalue()] * 3, [("bleu", 1, "flash"), ("bleu", 1, ""), ("bleu", 1, "tried")],
                      str(out), tile=200, gap=4)
    sheet = Image.open(out).convert("RGB")
    r, g, b = sheet.getpixel((2, 100))  # flash: gold frame
    assert r > 200 and g > 150 and b < 120
    assert sheet.getpixel((304, 100))[2] > 200  # plain top: untouched blue
    r, g, b = sheet.getpixel((508, 60))  # unsent: grey
    assert abs(r - b) < 20 and b < 100


def test_collage_survives_a_missing_font(tmp_path):
    import io

    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (100, 100), "white").save(buf, "JPEG")
    wm.render_collage([buf.getvalue()], [("bleu", 1, "tried")], str(tmp_path / "c.jpg"),
                      tile=100, font_path=str(tmp_path / "nope.ttf"))
    assert Image.open(tmp_path / "c.jpg").size == (100, 100)


def test_collage_grid_goes_four_wide_past_nine():
    assert [wm.collage_grid(n) for n in (10, 12, 16)] == [(4, 3), (4, 3), (4, 4)]


def test_games_section_after_music(tmp_path):
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")],
                music=[play("Club", "Lomepal", 250)], games=[game("Stardew Valley", 6000), game("Hades", 900)])
    op = memos_opener()
    wm.journal_day(cfg(tmp_path), pg, wm.Memos("http://m", "T", op), {}, date(2026, 10, 19), 1,
                   lambda m: None, no_render, str(tmp_path))
    text = op.body_of(1)["content"]
    assert ("\n\n### 🎮 Jeux - 1 h 55\n\n- **Stardew Valley** · 1 h 40\n- **Hades** · 15 min"
            "\n\n___________") in text and text.index("### 🎵 Musique") < text.index("### 🎮 Jeux")
    assert text.rstrip().endswith("#bike #music #gaming")
    sql = next(s for s in pg.sql if "video_game" in s)
    _, hi = wm.day_bounds(date(2026, 10, 19))
    assert f"to_timestamp({hi + 86400})" in sql


def test_activity_one_line_before_the_rides(tmp_path):
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")], games=[game("Hades", 900)],
                activity=[("step_count", 5940.4), ("distance_walking_running", 4376.1),
                          ("flights_climbed", 46.5), ("active_energy", 256.0)])
    op = memos_opener()
    wm.journal_day(cfg(tmp_path), pg, wm.Memos("http://m", "T", op), {}, date(2026, 10, 19), 1,
                   lambda m: None, no_render, str(tmp_path))
    text = op.body_of(1)["content"]
    assert text.startswith("### 🚶 Activité - 5 940 pas · 4,4 km · 46 étages · 256 kcal\n\n### 🚲 Vélo")
    sql = next(s for s in pg.sql if "health_metrics" in s)
    assert "coalesce(source, '') = ''" in sql and "DISTINCT ON (metric_name, time)" in sql


def test_activity_alone_makes_no_entry(tmp_path):
    op = memos_opener()
    pg = FakePg([], [], activity=[("step_count", 3000)])
    assert wm.journal_day(cfg(tmp_path), pg, wm.Memos("http://m", "T", op), {},
                          date(2026, 10, 19), 1, lambda m: None, no_render, str(tmp_path)) is None


def test_project_notes_collapse_in_their_own_section_and_are_cached(tmp_path):
    from test_journal_sources import DISPATCH
    pg, agent = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")]), []

    def run(cmd):
        if "log" in cmd:
            return "abc\n"
        if "-l" in cmd:
            agent.append(cmd)
            return DISPATCH
        return pg(cmd)
    c, state = cfg(tmp_path, dispatch_repos=("/home/nsimon/nic-os",)), {}
    after = wm.day_bounds(date(2026, 10, 19))[1] + 60
    wm.journal_day(c, run, wm.Memos("http://m", "T", memos_opener()), state, date(2026, 10, 19), 1,
                   lambda m: None, no_render, str(tmp_path), now=after)
    text = state["2026-10-19"]["text"]
    assert ("\n\n### 🛠 Projets perso\n\n<details>\n<summary>Notes</summary>\n\n"
            "Un seul correctif") in text
    assert "déploiement.\n\n</details>\n\n___________\n\n#bike #projects\n" in text
    assert "Travail" not in text
    assert state["_dispatch"]["2026-10-19"][2] == "**nic-os**" and len(agent) == 1
    state["2026-10-19"]["sig"] = "stale"
    wm.journal_day(c, run, wm.Memos("http://m", "T", update_opener({"name": "memos/M", "content": text})),
                   state, date(2026, 10, 19), 1, lambda m: None, no_render, str(tmp_path), now=after)
    assert len(agent) == 1  # cached: the agent ran once for the day


def test_project_notes_wait_for_the_day_to_end(tmp_path):
    c = cfg(tmp_path, dispatch_repos=("/r",), dry_run=True)
    run = lambda cmd: (_ for _ in ()).throw(AssertionError(cmd))
    assert wm.day_notes(c, run, {}, date(2026, 10, 19), print, now=wm.day_bounds(date(2026, 10, 19))[1] - 1) == []


def test_music_keeps_replays_and_fills_missing_artists_from_v1(tmp_path):
    lo, _ = wm.day_bounds(date(2026, 10, 19))
    pg = FakePg([], [], music=[("Club", "Lomepal", 250, lo + 3600, "aaa"),
                               ("Trop beau", "", 244, lo + 7200, "bbb"),
                               ("Club", "Lomepal", 250, lo + 9000, "aaa")],
                v1_artists=[("bbb", "Lomepal")])
    music = wm.day_music(cfg(tmp_path), pg, date(2026, 10, 19), print)
    assert music == ("3 titres · 12 min", ["- **Lomepal** · Club (2), Trop beau"])


def test_music_marks_an_artist_heard_three_days_running(tmp_path):
    lo, _ = wm.day_bounds(date(2026, 10, 19))
    pg = FakePg([], [], music=[("Club", "Lomepal", 250, lo - d * 86400 + 3600, "aaa") for d in (2, 1, 0)])
    music = wm.day_music(cfg(tmp_path), pg, date(2026, 10, 19), print)
    assert music == ("1 titre · 4 min", ["- **Lomepal** · Club · 🔥 3ᵉ jour d'affilée"])


def test_games_merge_v11_and_v1_playtime_a_day_late(tmp_path):
    lo, _ = wm.day_bounds(date(2026, 10, 19))
    push = lo + 86400 + 3000  # 04:50 the next morning
    pg = FakePg([], [], games=[(push, "Stardew Valley", 3600)], v1_games=[(push, "Hades", 600)])
    assert wm.day_games(cfg(tmp_path), pg, date(2026, 10, 19), print) == (
        "1 h 10", ["- **Stardew Valley** · 1 h 00", "- **Hades** · 10 min"])


def flight_row(fid, date_, dep, arr, frm=("CDG", "Paris (Roissy-en-France, Val-d'Oise)", "FR", 49.0097, 2.5479, "Europe/Paris"),
               to=("FCO", "Rome", "IT", 41.8003, 12.2389, "Europe/Rome"), seat=("36A", "economy"), duration=6300):
    ap = lambda a: (a[0], f"{a[1]} Airport", a[1], a[2], a[3], a[4], a[5])
    return (fid, date_, dep, arr, duration, "AF1104", "Air France", "Airbus A321", "F-GTAZ", "2F",
            *ap(frm), *ap(to), *seat)


def test_flight_day_gets_a_section_and_a_boarding_pass(tmp_path):
    flights = [flight_row(1, "2025-10-03", "2025-10-03T13:20:00.000+00:00", "",
                          to=("EDI", "Edinburgh", "GB", 55.95, -3.37, "Europe/London"), seat=("", "")),
               flight_row(2, "2026-10-19", "2026-10-19T07:25:00.000+00:00", "2026-10-19T09:10:00.000+00:00")]
    op = FakeOpener([json_reply({"name": "attachments/F"}), json_reply({"name": "memos/M"}),
                     json_reply({"name": "memos/M"})])
    passes = []
    wm.journal_day(cfg(tmp_path, airtrail_url="https://air"), FakePg([], [], flights=flights),
                   wm.Memos("http://m", "T", op), {}, date(2026, 10, 19), 1, lambda m: None, no_render,
                   str(tmp_path), pass_fn=lambda fs, path: (passes.append([f.id for f in fs]), no_render(None, path)))
    assert passes == [[2]] and op.body_of(0)["filename"] == "flight-2026-10-19.jpg"
    memo = op.body_of(1)
    assert memo["content"] == (
        "### ✈️ Vol - Paris → Rome · 1 101 km · 1h45\n\n"
        "- 🎫 **AF1104** · Air France · Airbus A321 · F-GTAZ\n"
        "- 🛫 **09:25** · CDG 🇫🇷 Paris · terminal 2F\n"
        "- 🛬 **11:10** · FCO 🇮🇹 Rome\n"
        "- 💺 36A · économie\n"
        "- 📊 2ᵉ vol · 1 969 km en avion depuis 2025\n"
        "- 🆕 Premier vol vers 🇮🇹\n\n"
        "[Voir dans AirTrail](https://air)\n\n___________\n\n#flight\n")
    assert memo["location"]["placeholder"] == "Rome"
    assert op.body_of(2) == {"createTime": "2026-10-19T09:10:00Z"}


def test_a_dateonly_flight_and_a_red_eye(tmp_path):
    from nicos_scripts.connectors import journal_flights as fl
    rows = [flight_row(1, "2026-10-19", "", "", seat=("", "")),
            flight_row(2, "2026-10-20", "2026-10-20T00:30:00.000+00:00", "")]  # 02:30 Paris: still the 19th's day
    every = fl.all_flights(FakePg([], [], flights=rows))
    assert every[1].arr.isoformat() == "2026-10-20T02:15:00+00:00"  # departure + duration
    lo, hi = wm.day_bounds(date(2026, 10, 19))
    assert [f.id for f in fl.on_day(every, date(2026, 10, 19), lo, hi)] == [1, 2]
    head, lines = fl.flight_section(every, every)
    assert head.startswith("Paris → Rome · 2 20") and head.endswith(" km · 3h30")


def test_boarding_pass_draws_without_network(tmp_path):
    from PIL import Image

    from nicos_scripts.connectors import journal_flights as fl
    f = fl.all_flights(FakePg([], [], flights=[flight_row(1, "2026-10-19", "2026-10-19T07:25:00.000+00:00", "")]))[0]
    wm.render_boarding_passes([f, f], str(tmp_path / "p.jpg"),
                              map_fn=lambda _: Image.new("RGB", (wm.PASS_W, wm.PASS_MAP_H), "black"))
    img = Image.open(tmp_path / "p.jpg")
    assert img.size == (wm.PASS_W, 2 * (wm.PASS_MAP_H + wm.PASS_TICKET_H) + 12)


def test_great_circle_ends_at_both_airports():
    from nicos_scripts.connectors import journal_flights as fl
    f = fl.all_flights(FakePg([], [], flights=[flight_row(1, "2026-10-19", "", "")]))[0]
    arc = fl.great_circle(f)
    assert arc[0] == pytest.approx((49.0097, 2.5479)) and arc[-1] == pytest.approx((41.8003, 12.2389))
    assert fl.flag("it") == "🇮🇹"


def test_genealogy_collapses_past_three_events_with_the_count_in_the_title():
    three = [f"- e{i}" for i in range(3)]
    text = wm.content("2026-10-19", [], [], "w", genealogy=three)
    assert text.startswith("### 🌳 Généalogie - 3 événements\n\n- e0\n- e1\n- e2\n")
    text = wm.content("2026-10-19", [], [], "w", genealogy=three + ["- e3"])
    assert text.startswith("### 🌳 Généalogie - 4 événements\n\n<details>\n<summary>Ce jour-là</summary>\n\n"
                           "- e0\n- e1\n- e2\n- e3\n\n</details>")


def test_home_section_collapses_the_electricity_detail():
    text = wm.content("2026-10-19", [], [], "w", energy=("25,1 kWh · 3,15 €", ["- 🔥 heat"]))
    assert text == ("### 🏠 Maison - ⚡ 25,1 kWh · 3,15 €\n\n<details>\n<summary>Électricité</summary>\n\n"
                    "- 🔥 heat\n\n</details>\n\n___________\n\n#home\n")
    assert wm.content("2026-10-19", [], [], "w", energy=("1,0 kWh", [])).startswith("### 🏠 Maison - ⚡ 1,0 kWh\n\n___")


def test_the_day_ends_with_work_memories_home_genealogy():
    text = wm.content("2026-10-19", [], [], "w", work=(1, 30, 2, []), memories=["- m"],
                      energy=("1,0 kWh", []), genealogy=["- g"], music=("1 titre", ["- t"]))
    heads = [l.split(" - ")[0] for l in text.splitlines() if l.startswith("### ")]
    assert heads == ["### 🎵 Musique", "### 💼 Travail", "### 🕰 Souvenirs", "### 🏠 Maison", "### 🌳 Généalogie"]


def test_summary_on_top_cached_and_retried(tmp_path):
    calls = []

    def summary(text):
        calls.append(text)
        return None if len(calls) == 1 else "Une sortie à vélo dans Paris."

    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")])
    state, lines = {}, []
    run = lambda op: wm.journal_day(cfg(tmp_path), pg, wm.Memos("http://m", "T", op), state,
                                    date(2026, 10, 19), 1, lines.append, no_render, str(tmp_path), summary_fn=summary)
    run(memos_opener())  # gate down: memo without summary, retried next run
    assert any("no summary this run" in l for l in lines) and not state["2026-10-19"]["text"].startswith("*")
    op = FakeOpener([json_reply({"name": "attachments/A"}), json_reply({}), json_reply({}), json_reply({})])
    run(op)
    assert state["2026-10-19"]["text"].startswith("*Une sortie à vélo dans Paris.*\n\n")
    state["2026-10-19"]["sig"] = "stale"  # same content: the cached sentence, no new call
    run(FakeOpener([json_reply({"name": "attachments/A"}), json_reply({}), json_reply({}), json_reply({})]))
    assert len(calls) == 2


def test_catchup_reruns_only_older_days_whose_spending_moved(tmp_path):
    c = cfg(tmp_path, day="")
    today = date(2026, 10, 26)
    spend_fn = lambda day: [wm.spend.Spend(False, 12.5, "Franprix", "0 - Groceries")]
    same = list(wm.spend.spend_section([wm.spend.Spend(False, 12.5, "Franprix", "0 - Groceries")], 10))
    state = {"2026-10-16": {"memo": "memos/A", "spend": [same[0], same[1]]},  # unchanged
             "2026-10-15": {"memo": "memos/B"},  # written before the purchase landed
             "2026-10-01": {"memo": "memos/C"},  # past the window
             "2026-10-24": {"memo": "memos/D"}}  # a regular target day
    assert wm.catchup_days(c, spend_fn, state, today) == [date(2026, 10, 15)]
    assert wm.catchup_days(cfg(tmp_path, day="2026-10-15"), spend_fn, state, today) == []
    assert wm.catchup_days(c, None, state, today) == []


def test_redo_file_lists_past_days_only(tmp_path):
    f = tmp_path / "days"
    f.write_text("2026-10-19\n2026-04-30 junk 2026-13-01\n2026-10-27 2016-12-31 2026-10-19\n")
    c = cfg(tmp_path, day="", redo_file=str(f))
    assert wm.target_days(c, date(2026, 10, 27)) == [date(2026, 4, 30), date(2026, 10, 19)]
    assert wm.catchup_days(c, lambda d: [], {}, date(2026, 10, 27)) == []
    assert wm.target_days(cfg(tmp_path, day="", redo_file=str(tmp_path / "none")), date(2026, 10, 27)) == []


def test_redo_file_refuses_a_symlink(tmp_path):
    secret = tmp_path / "secret"
    secret.write_text("2026-10-19\n")
    (tmp_path / "days").symlink_to(secret)
    with pytest.raises(OSError):
        wm.redo_days(str(tmp_path / "days"), date(2026, 10, 27))
