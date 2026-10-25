import json

from conftest import FakeOpener, json_reply
from nicos_scripts.connectors import immich_dawarich as im

SEP = "\x1f"
NOW = 1_800_000_000


class FakePg:
    def __init__(self, settings=("https://immich.test/", "IKEY"), backfill=1_776_703_425):
        self.settings, self.backfill = settings, backfill

    def __call__(self, cmd):
        sql = cmd[cmd.index("-c") + 1]
        if "immich_url" in sql:
            rows = [self.settings]
        elif "ORDER BY id" in sql:
            rows = [("1", "DKEY")]
        elif "tracker_id FROM points" in sql:
            rows = [("PHONE",)]
        elif "max(p.timestamp)" in sql:
            rows = [(self.backfill,)]
        else:
            raise AssertionError(sql)
        return "\n".join(SEP.join(str(v) for v in r) for r in rows)


def asset(aid, lat=48.8, lon=2.3, when="2026-10-20T08:00:00.000Z", **kw):
    return {"id": aid, "fileCreatedAt": when,
            "exifInfo": {"latitude": lat, "longitude": lon}, **kw}


def page(items, next_page=None):
    return json_reply({"assets": {"items": items, "nextPage": next_page}})


def cfg(tmp_path, **kw):
    return im.Config(**{"state_path": str(tmp_path / "s.json"), "dry_run": False, **kw})


def bodies(opener, path):
    return [json.loads(r.data) for r in opener.requests if r.full_url.endswith(path)]


def test_first_run_backfills_from_last_import_and_pages(tmp_path):
    op = FakeOpener([page([asset("a")], "2"), page([asset("b", lat=None)]), json_reply({})])
    sent = im.sync(cfg(tmp_path), FakePg(), opener=op, log=lambda _: None, now=lambda: NOW)
    search = bodies(op, "/api/search/metadata")
    assert search[0]["takenAfter"] == "2026-04-20T16:43:45Z"
    assert [b["page"] for b in search] == [1, 2]
    assert op.requests[0].full_url == "https://immich.test/api/search/metadata"
    assert op.requests[0].get_header("X-api-key") == "IKEY"
    (push,) = bodies(op, "/api/v1/points")
    feat = push["locations"][0]
    assert sent == 1 and len(push["locations"]) == 1
    assert feat["geometry"]["coordinates"] == [2.3, 48.8]
    assert feat["properties"]["device_id"] == "PHONE"
    assert feat["properties"]["timestamp"] == 1_792_483_200
    assert op.requests[-1].get_header("Authorization") == "Bearer DKEY"
    assert json.loads((tmp_path / "s.json").read_text()) == {"last_run": NOW}


def test_next_run_asks_for_updates_since_last_run_minus_overlap(tmp_path):
    (tmp_path / "s.json").write_text(json.dumps({"last_run": NOW}))
    op = FakeOpener([page([])])
    assert im.sync(cfg(tmp_path), FakePg(), opener=op, log=lambda _: None,
                   now=lambda: NOW + 86400) == 0
    (search,) = bodies(op, "/api/search/metadata")
    assert search["updatedAfter"] == im._iso(NOW - im.OVERLAP_S)
    assert not bodies(op, "/api/v1/points")


def test_skips_trashed_locked_and_zero_gps():
    assert im.fix(asset("a", isTrashed=True)) is None
    assert im.fix(asset("a", visibility="locked")) is None
    assert im.fix(asset("a", lat=0)) is None
    assert im.fix(asset("a", when=None)) is None
    assert im.fix(asset("a", visibility="archive"))[3] == "a"


def test_dry_run_neither_pushes_nor_saves(tmp_path):
    op = FakeOpener([page([asset("a")])])
    im.sync(cfg(tmp_path, dry_run=True), FakePg(), opener=op, log=lambda _: None)
    assert not bodies(op, "/api/v1/points")
    assert not (tmp_path / "s.json").exists()


def test_unconfigured_immich_fails_loudly():
    pg = FakePg(settings=("", ""))
    assert im.main({"IMMICH_DAWARICH_DRY_RUN": "0"}, run=pg, opener=FakeOpener()) == 1


def test_default_config_cannot_write():
    assert im.Config.from_env({}).dry_run is True
