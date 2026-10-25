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

    def __init__(self, workouts, points, place=None, areas=(("75013", "Paris"),)):
        self.workouts, self.points, self.place, self.areas = workouts, points, place, areas
        self.sql = []

    def __call__(self, cmd):
        sql = cmd[cmd.index("-c") + 1]
        self.sql.append(sql)
        if "FROM workouts" in sql:
            rows = self.workouts
        elif "FROM users" in sql:
            rows = [("1",)]
        elif "FROM places" in sql:
            rows = [(self.place,)] if self.place else []
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
    text = wm.content("2026-10-19", ws, [("Home", "Work"), ("Work", "Home")], "https://d")
    assert text.startswith("### 🚲 Bike — 2 rides · 19.3 km · 1 h 22 · 612 kcal\n\n")
    assert "- **08:13** Home → Work · 9.5 km · 37 min · 15.4 km/h" in text
    assert "date=2026-10-19" in text
    assert text.rstrip().endswith("#bike #commute")


def test_content_mixed_kinds_prefixes_each_line():
    ws = [wm.Workout(W1, "Cycling", T1, T1 + 600, 3, 10, 0),
          wm.Workout(W2, "Running", T2, T2 + 1800, 5, 30, 0)]
    text = wm.content("2026-10-19", ws, [None, None], "https://d")
    assert text.startswith("### 🏅 Workouts — 2 workouts · 8.0 km · 40 min")
    assert "- 🏃 **18:31** Running" in text
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


def test_changed_day_replaces_the_old_memo(tmp_path):
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")])
    state = {"2026-10-19": {"memo": "memos/OLD", "sig": "stale"}}
    op = FakeOpener([
        json_reply({"name": "memos/OLD", "attachments": [{"name": "attachments/OLDA"}]}),
        json_reply({}), json_reply({}),
        json_reply({"name": "attachments/A"}), json_reply({"name": "memos/M"}), json_reply({"name": "memos/M"}),
    ])
    run_day(cfg(tmp_path), pg, op, state)
    calls = [(r.get_method(), r.full_url.rsplit("/v1", 1)[-1]) for r in op.requests[:3]]
    assert calls == [("GET", "/memos/OLD"), ("DELETE", "/attachments/OLDA"), ("DELETE", "/memos/OLD")]
    assert state["2026-10-19"]["memo"] == "memos/M"


def test_day_without_workouts_posts_nothing(tmp_path):
    op = memos_opener()
    assert run_day(cfg(tmp_path), FakePg([], []), op, {}) is None
    assert op.requests == []


def test_dry_run_posts_nothing(tmp_path):
    pg = FakePg([ride(W1, T1)], [("48.83", "2.34"), ("48.91", "2.33")])
    op, state = memos_opener(), {}
    run_day(cfg(tmp_path, dry_run=True), pg, op, state)
    assert op.requests == [] and state == {}


def test_named_place_wins_over_the_area(tmp_path):
    assert wm.place(cfg(tmp_path), FakePg([], [], place="Home"), 1, 48.83, 2.34) == "Home"
    pg = FakePg([], [])
    assert wm.place(cfg(tmp_path), pg, 1, 48.83, 2.34) == "Paris 13e"
    radius = next(s for s in pg.sql if "FROM places" in s)
    assert "source = 0" in radius and ", 300)" in radius


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
    assert collages == [["13:00", "14:00"]] and im.previews == ["p1", "p2"]
    memo = op.body_of(2)
    assert [a["name"] for a in memo["attachments"]] == ["attachments/MAP", "attachments/COL"]
    assert "\n\n### 📷 Photos — 2\n\n[Open the day in Immich](https://immich/photos/p1)\n" in memo["content"]
    assert memo["content"].rstrip().endswith("#bike #photos")


def test_photo_only_day_is_dated_and_pinned_by_the_last_photo(tmp_path):
    im = FakeImmich([photo(1), photo(3, gps=False)])
    op = FakeOpener([json_reply({"name": "attachments/COL"}),
                     json_reply({"name": "memos/M"}), json_reply({"name": "memos/M"})])
    wm.journal_day(cfg(tmp_path), FakePg([], []), wm.Memos("http://m", "T", op), {},
                   date(2026, 10, 19), 1, lambda m: None, no_render, str(tmp_path), im,
                   collage_fn=lambda imgs, labels, path: no_render(None, path))
    memo = op.body_of(1)
    assert memo["content"].startswith("### 📷 Photos — 2\n\n[Open the day in Immich](https://immich/photos/p1)")
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
    assert [a["id"] for a in wm.pick_photos(day, 9)] == ["m", "b3", "e"]
    day[5]["isFavorite"] = True
    assert [a["id"] for a in wm.pick_photos(day, 9)] == ["m", "b4", "e"]


def test_a_loop_reads_around_its_place():
    ws = [wm.Workout(W1, "Cycling", T1, T1 + 420, 2.3, 7, 50)]
    assert "- **08:13** around Paris 13e · 2.3 km" in wm.content("2026-10-19", ws, [("Paris 13e", "Paris 13e")], "d")


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
                       jpeg("white", (400, 400))], ["08:12", "12:31", "14:29", "17:57"],
                      str(out), tile=100, gap=4)
    sheet = Image.open(out)
    assert sheet.size == (204, 204)
    assert sheet.getpixel((50, 10))[0] > 200            # top-left tile is red
    assert sheet.getpixel((150, 10))[2] > 200           # top-right tile is blue
    assert sheet.getpixel((8, 92)) != sheet.getpixel((50, 10))  # label box drawn
