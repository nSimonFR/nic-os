import json
from datetime import date

from conftest import FakeOpener, json_reply
from nicos_scripts.connectors import journal_daily as wm

SEP = "\x1f"
W1 = "11111111-1111-1111-1111-111111111111"
W2 = "22222222-2222-2222-2222-222222222222"
# 2026-10-19 08:13 and 18:31 Europe/Paris
T1, T2 = 1792390421, 1792427478


class FakePg:
    """Answers psql_rows by matching on the SQL text."""

    def __init__(self, workouts, points, place=None, areas=(("75013", "Paris"),), tracks=(), music=(), games=()):
        self.workouts, self.points, self.place, self.areas = workouts, points, place, areas
        self.tracks, self.music, self.games = tracks, music, games
        self.sql = []

    def __call__(self, cmd):
        sql = cmd[cmd.index("-c") + 1]
        self.sql.append(sql)
        if "oc_calendarobjects" in sql:
            rows = []
        elif "FROM workouts" in sql:
            rows = self.workouts
        elif "FROM seen" in sql and "video_game" in sql:
            rows = self.games
        elif "FROM seen" in sql:
            rows = self.music
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


def cfg(tmp_path, **kw):
    base = dict(state_path=str(tmp_path / "state.json"), dry_run=False, day="2026-10-19")
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
    def __init__(self, assets=(), fail=False):
        self.assets, self.fail, self.previews = list(assets), fail, []

    def day(self, day):
        if self.fail:
            raise OSError("connection refused")
        return self.assets

    def preview(self, asset_id):
        self.previews.append(asset_id)
        return b"JPG"

    def link(self, asset_id):
        return f"https://immich/photos/{asset_id}"


def photo(n, fav=False, gps=True):
    exif = {"latitude": 48.85, "longitude": 2.35, "city": "Paris"} if gps else {}
    return {"id": f"p{n}", "fileCreatedAt": f"2026-10-19T{10 + n:02d}:00:00.000Z",
            "isFavorite": fav, "exifInfo": exif}


def test_pick_photos_favourites_first_then_spread():
    assets = [photo(n) for n in range(10)]
    assets[7]["isFavorite"] = True
    assert [a["id"] for a in wm.pick_photos(assets, 3)] == ["p2", "p6", "p7"]
    assert [a["id"] for a in wm.pick_photos(assets[:2], 6)] == ["p0", "p1"]
    assert wm.pick_photos(assets, 0) == []


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
    plays = [("Club", "Lomepal", 250), ("Starlight", "Muse", 240), ("Trop beau", "Lomepal", 244),
             ("Un peu de sang", "Lomepal", 305)]
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")], music=plays)
    op = memos_opener()
    wm.journal_day(cfg(tmp_path), pg, wm.Memos("http://m", "T", op), {}, date(2026, 10, 19), 1,
                   lambda m: None, no_render, str(tmp_path))
    text = op.body_of(1)["content"]
    assert ("\n\n### 🎵 Musique - 4 titres · 17 min\n\n"
            "- **Lomepal** · Club, Trop beau, Un peu de sang\n- **Muse** · Starlight\n\n___________\n\n#bike #music\n") in text


def test_music_alone_makes_no_entry(tmp_path):
    op = memos_opener()
    pg = FakePg([], [], music=[("Club", "Lomepal", 250)])
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


def test_climbing_mosaic_of_topped_boulders_hardest_first(tmp_path):
    def b(bid, label, share):
        return {"_id": bid, "label": label, "picture": {"id": "i" + bid, "share": share}}
    sess = {**SESSION, "boulders": [b("g1", 4, "S1"), b("b1", 5, "S2"), b("np", 4, None) | {"picture": {}}],
            "retopBoulders": [b("g2", 4, None)], "triedBoulders": [b("t", 5, "ST")]}
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
                       f"{s3}/800/bouldersPics/ig2.jpg"]
    assert mosaics == [[("bleu", 1), ("vert", 1)]]
    assert op.body_of(0)["filename"] == "climbing-2026-10-19.jpg"
    assert "boulder picture unavailable" in lines[0]


def test_collage_grid_goes_four_wide_past_nine():
    assert [wm.collage_grid(n) for n in (10, 12, 16)] == [(4, 3), (4, 3), (4, 4)]


def test_games_section_after_climbing_before_music(tmp_path):
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")],
                music=[("Club", "Lomepal", 250)], games=[("Stardew Valley", 6000), ("Hades", 900)])
    op = memos_opener()
    wm.journal_day(cfg(tmp_path), pg, wm.Memos("http://m", "T", op), {}, date(2026, 10, 19), 1,
                   lambda m: None, no_render, str(tmp_path))
    text = op.body_of(1)["content"]
    assert ("\n\n### 🎮 Jeux - 1 h 55\n\n- **Stardew Valley** · 1 h 40\n- **Hades** · 15 min"
            "\n\n### 🎵 Musique") in text
    assert text.rstrip().endswith("#bike #gaming #music")
    sql = next(s for s in pg.sql if "video_game" in s)
    lo, hi = wm.day_bounds(date(2026, 10, 19))
    assert f"to_timestamp({lo + 86400})" in sql and f"to_timestamp({hi + 86400})" in sql
