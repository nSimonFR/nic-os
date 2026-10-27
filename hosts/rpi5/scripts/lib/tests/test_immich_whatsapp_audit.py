"""immich-whatsapp-audit: integrity → disable, false positives, spike, silence."""

import json

import pytest

from conftest import FakeResponse
from nicos_scripts.immich import whatsapp_audit as wa

GOOD_WF = [{"enabled": True, "name": "WhatsApp"}]
GOOD_STEPS = [
    {"name": "assetFileFilter", "enabled": True, "config": wa.FILTER_CONFIG},
    {"name": "assetArchive", "enabled": True, "config": {}},
]


class FakeRun:
    """Answers psql by matching the SQL, records telegram-send calls."""

    def __init__(self, order=wa.STEPS, wf=GOOD_WF, steps=GOOD_STEPS,
                 assets=(), volumes=(0,) * 9, tg='{"ok":true}'):
        self.order, self.wf, self.steps = order, wf, steps
        self.assets, self.volumes, self.tg = assets, volumes, tg
        self.sent = []

    def __call__(self, argv, stdin_text=None):
        if argv[0] != "psql":
            self.sent.append(stdin_text)
            return self.tg
        sql = argv[-1]
        lines = lambda rows: "\n".join(json.dumps(r) for r in rows)
        if "FROM plugin_method WHERE" in sql:
            return "\n".join(self.order)
        if "FROM workflow WHERE" in sql:
            return lines(self.wf)
        if "FROM workflow_step" in sql:
            return lines(self.steps)
        if "generate_series" in sql:
            return lines({"archived": v} for v in self.volumes)
        if "array_agg" in sql:
            return lines(self.assets)
        if "count(*)" in sql:
            return "42"
        raise AssertionError(sql)


def _asset(**kw):
    base = {"id": "a1", "originalFileName": "0f8fad5b-d9cb-469f-a165-70867728950e.jpg",
            "createdAt": "2026-10-26T10:00:00", "make": None, "model": None,
            "albums": [], "in_whatsapp": False}
    return {**base, **kw}


def test_all_well_is_silent():
    run = FakeRun()
    assert wa.run_audit(wa.Config(), run=run) == ""
    assert run.sent == []


@pytest.mark.parametrize("kw", [
    {"order": ["assetArchive", "assetFileFilter"]},
    {"wf": []},
    {"wf": [{"enabled": False}]},
    {"steps": GOOD_STEPS[:1]},
    {"steps": [dict(GOOD_STEPS[0], enabled=False), GOOD_STEPS[1]]},
    {"steps": [dict(GOOD_STEPS[0], config={"pattern": ".*"}), GOOD_STEPS[1]]},
])
def test_drift_disables_the_workflow_then_alerts(kw, opener):
    run, fake = FakeRun(**kw), opener([lambda: FakeResponse(b"{}")])
    msg = wa.run_audit(wa.Config(), run=run, opener=fake, key="K")
    req = fake.last
    assert req.get_method() == "PUT" and req.full_url.endswith(f"/api/workflows/{wa.WORKFLOW}")
    assert req.data == b'{"enabled":false}' and req.get_header("X-api-key") == "K"
    assert "Workflow disabled." in msg and "last 7 days: 42" in msg
    assert run.sent == [msg]


def test_failed_disable_still_alerts_and_says_so(opener):
    def boom():
        raise OSError("connection refused")
    msg = wa.run_audit(wa.Config(), run=FakeRun(wf=[]), opener=opener([boom]), key="K")
    assert "DISABLE FAILED (connection refused)" in msg


def test_false_positive_rules():
    assets = [
        _asset(id="wa", in_whatsapp=True, albums=["Holidays"]),
        _asset(id="plain"),
        _asset(id="auto", albums=["Recents", "[AUTO] Faces"]),
        _asset(id="cur", albums=["Recents", "Holidays"]),
        _asset(id="cam", make="SONY", model="ILCE-7M3"),
        _asset(id="ip16", make="Apple", model="iPhone 16 Pro"),
    ]
    got = {a["id"]: a["reason"] for a in wa.reportable(assets)}
    assert got == {"cur": "curated album", "cam": "non-phone camera", "ip16": "iPhone 16 family"}


def test_flagged_assets_are_reported_with_links():
    run = FakeRun(assets=[_asset(id="cur", albums=["A & B"])])
    msg = wa.run_audit(wa.Config(), run=run)
    assert f'<a href="{wa.PUBLIC}cur">' in msg and "A &amp; B" in msg
    assert run.sent == [msg]


@pytest.mark.parametrize("volumes, expected", [
    ([19] + [0] * 8, None),
    ([20] + [0] * 8, (20, 0)),
    ([29] + [10] * 8, None),
    ([30] + [10] * 8, (30, 10)),
    ([], None),
])
def test_spike_threshold(volumes, expected):
    assert wa.spike(volumes) == expected


def test_telegram_rejection_is_a_failure():
    run = FakeRun(assets=[_asset(albums=["Holidays"])], tg='{"ok":false}')
    with pytest.raises(RuntimeError, match="rejected"):
        wa.run_audit(wa.Config(), run=run)


def test_main_exits_nonzero_when_psql_fails(monkeypatch, capsys):
    def run(argv, stdin_text=None):
        raise RuntimeError("psql exited 2: peer authentication failed")
    monkeypatch.setattr(wa, "_run", run)
    monkeypatch.setattr(wa.run_audit, "__defaults__", (run, None, None))
    assert wa.main(env={}) == 1
    assert capsys.readouterr().out == ""
