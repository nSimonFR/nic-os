"""hermes-whatsapp-audit: integrity → disable, false positives, spike, silence."""

import json
from datetime import datetime, timezone

import pytest

from conftest import FakeResponse
from nicos_scripts.hermes import whatsapp_audit as wa

NOW = datetime(2026, 10, 28, 9, 0, tzinfo=timezone.utc)  # a Wednesday
GOOD_WF = {"id": wa.WORKFLOW, "enabled": True, "steps": [
    {"method": wa.STEPS[0], "enabled": True, "config": wa.FILTER_CONFIG},
    {"method": wa.STEPS[1], "enabled": True, "config": {}},
]}
UUID_NAME = "0f8fad5b-d9cb-469f-a165-70867728950e.jpg"


class Immich:
    """Routes requests by path; records them."""

    def __init__(self, wf=GOOD_WF, assets=(), albums=None, volumes=None, put=200):
        self.wf, self.assets, self.albums = wf, list(assets), albums or {}
        self.volumes = list(volumes or [0] * 9)
        self.put, self.requests = put, []

    def __call__(self, req, timeout=None):
        self.requests.append(req)
        url, body = req.full_url, json.loads(req.data or b"{}")
        if req.get_method() == "PUT":
            if isinstance(self.put, Exception):
                raise self.put
            return FakeResponse(b"{}", self.put)
        if "/workflows/" in url:
            return self._json(self.wf)
        if "/albums?assetId=" in url:
            return self._json(self.albums.get(url.rsplit("=", 1)[1], []))
        if url.endswith("/search/metadata"):
            return self._json({"assets": {"items": self.assets, "nextPage": None}})
        if url.endswith("/search/statistics"):
            return self._json({"total": self.volumes.pop(0) if self.volumes else 0})
        raise AssertionError(url)

    @staticmethod
    def _json(obj):
        return FakeResponse(json.dumps(obj).encode())

    def puts(self):
        return [r for r in self.requests if r.get_method() == "PUT"]


def _asset(id="a1", name=UUID_NAME, make=None, model=None):
    return {"id": id, "originalFileName": name, "createdAt": "2026-10-27T10:00:00Z",
            "exifInfo": {"make": make, "model": model}}


def test_defaults_route_immich_through_agent_vault():
    cfg = wa.Config.from_env({})
    assert (cfg.immich_url, cfg.api_key) == ("http://immich.home.arpa:2283", "__immich_api_key__")


def test_all_well_is_silent_and_writes_nothing():
    imm = Immich(assets=[_asset()])
    assert wa.run(wa.Config(), now=NOW, opener=imm) == ""
    assert imm.puts() == []
    assert all(r.get_header("X-api-key") == "__immich_api_key__" for r in imm.requests)


@pytest.mark.parametrize("wf", [
    dict(GOOD_WF, enabled=False),
    dict(GOOD_WF, steps=GOOD_WF["steps"][::-1]),
    dict(GOOD_WF, steps=GOOD_WF["steps"][:1]),
    dict(GOOD_WF, steps=[dict(GOOD_WF["steps"][0], enabled=False), GOOD_WF["steps"][1]]),
    dict(GOOD_WF, steps=[dict(GOOD_WF["steps"][0], config={"pattern": ".*"}),
                         GOOD_WF["steps"][1]]),
    {},
])
def test_drift_disables_the_workflow_then_reports(wf):
    imm = Immich(wf=wf, volumes=[42])
    msg = wa.run(wa.Config(), now=NOW, opener=imm)
    (put,) = imm.puts()
    assert put.full_url.endswith(f"/api/workflows/{wa.WORKFLOW}")
    assert put.data == b'{"enabled":false}'
    assert "Workflow disabled." in msg and "last 7 days: 42" in msg


@pytest.mark.parametrize("put, shown", [
    (OSError("connection refused"), "DISABLE FAILED (connection refused)"),
    (202, "Workflow disabled."),
])
def test_disable_outcome_is_reported(put, shown):
    msg = wa.run(wa.Config(), now=NOW, opener=Immich(wf={}, put=put))
    assert shown in msg


def test_false_positive_rules():
    wa_album = {"id": wa.WHATSAPP_ALBUM, "albumName": "WhatsApp"}
    cases = {
        "wa": ([wa_album, {"albumName": "Holidays"}], _asset(), []),
        "plain": ([], _asset(), []),
        "auto": ([{"albumName": "Recents"}, {"albumName": "[AUTO] Faces"}], _asset(), []),
        "cur": ([{"albumName": "Recents"}, {"albumName": "Holidays"}], _asset(),
                ["curated album: Holidays"]),
        "cam": ([], _asset(make="SONY", model="ILCE-7M3"), ["non-phone camera"]),
        "ip16": ([], _asset(make="Apple", model="iPhone 16 Pro"), ["iPhone 16 family"]),
    }
    for name, (albums, asset, expected) in cases.items():
        assert wa.classify(asset, albums) == expected, name


def test_only_uuid_names_are_considered():
    imm = Immich(assets=[_asset("x", name="IMG_8495.PNG", make="SONY"), _asset("y", make="SONY")])
    msg = wa.run(wa.Config(), now=NOW, opener=imm)
    assert "Possible false positives: 1" in msg and f"{wa.PUBLIC}y" in msg
    assert not any("assetId=x" in r.full_url for r in imm.requests)


def test_weekly_volumes_use_utc_monday_bounds():
    imm = Immich(volumes=range(9))
    assert wa.weekly_volumes(wa.Config(), NOW, opener=imm) == list(range(9))
    stats = [json.loads(r.data) for r in imm.requests]
    assert stats[0] == {"visibility": "archive", "createdAfter": "2026-10-26T00:00:00+00:00"}
    assert stats[1]["createdAfter"] == "2026-10-19T00:00:00+00:00"
    assert stats[1]["createdBefore"] == "2026-10-26T00:00:00+00:00"


@pytest.mark.parametrize("volumes, expected", [
    ([19] + [0] * 8, None),
    ([20] + [0] * 8, (20, 0)),
    ([29] + [10] * 8, None),
    ([30] + [10] * 8, (30, 10)),
])
def test_spike_threshold(volumes, expected):
    assert wa.spike(volumes) == expected


def test_spike_alone_is_reported():
    msg = wa.run(wa.Config(), now=NOW, opener=Immich(volumes=[25] + [1] * 8))
    assert "Archive volume spike: 25 this week; trailing 8-week median 1." in msg


def test_main_exits_nonzero_when_immich_is_unreachable(capsys):
    assert wa.main(env={"IMMICH_URL": "http://127.0.0.1:9"}) == 1
    assert capsys.readouterr().out == ""
