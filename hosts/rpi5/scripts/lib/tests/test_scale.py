"""scale-to-ryot: the QN payload translation and the webhook's contract.

The handler tests run a real ThreadingHTTPServer on an ephemeral port with the
Ryot push replaced by a recorder — the shim's whole job is HTTP status codes, and
those are only worth testing against a real socket.
"""

import inspect
import io
import json
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import pytest
from conftest import FakeOpener, json_reply

from nicos_scripts import ryot
from nicos_scripts.connectors import scale

FULL_FRAME = {
    "weight": 82.35,
    "impedance": 510,
    "bmi": 24.1,
    "bodyFatPercent": 18.5,
    "waterPercent": 55.0,
    "boneMass": 3.2,
    "muscleMass": 63.4,
    "visceralFat": 8,
    "physiqueRating": 5,
    "bmr": 1785,
    "metabolicAge": 29,
}


# ── build_statistics ──────────────────────────────────────────────────────────


def test_every_mapped_field_is_translated_to_its_ryot_metric_key():
    stats = {s["name"]: s["value"] for s in scale.build_statistics(FULL_FRAME)}
    assert stats["body_fat"] == "18.5"
    assert stats["basal_metabolic_rate"] == "1785"
    assert set(stats) == set(scale.FIELD_MAP.values())


def test_zeros_are_dropped_except_weight():
    # QN scales emit 0 for body-comp fields on the weight-only frame (before
    # impedance settles); pushing those would log a bogus reading.
    stats = scale.build_statistics({"weight": 82.0, "bodyFatPercent": 0, "bmi": 0})
    assert stats == [{"name": "weight", "value": "82"}]


def test_a_zero_weight_is_still_reported():
    assert scale.build_statistics({"weight": 0}) == [{"name": "weight", "value": "0"}]


def test_absent_and_non_numeric_fields_are_skipped():
    stats = scale.build_statistics({"weight": "82.35", "bmi": "n/a", "muscleMass": None})
    assert stats == [{"name": "weight", "value": "82.35"}]


def test_unknown_fields_are_ignored():
    assert scale.build_statistics({"user_slug": "nico", "battery": 99}) == []


def test_values_are_formatted_as_trimmed_strings():
    # %g drops the trailing .0 noise; push_to_ryot turns them into JSON numbers.
    stats = scale.build_statistics({"weight": 82.50, "bmi": 24.000})
    assert stats == [
        {"name": "weight", "value": "82.5"},
        {"name": "bmi", "value": "24"},
    ]


# ── push_to_ryot ──────────────────────────────────────────────────────────────

TS = "2026-08-06T00:00:00+00:00"
METRICS = {
    "data": {
        "metrics": {
            "type": "rows",
            "pageInfo": {"limit": 100, "hasMore": False, "nextCursor": None},
            "items": [
                {"id": "m-weight", "key": "weight"},
                {"id": "m-bmi", "key": "bmi"},
                {"id": "m-legacy", "key": None},
            ],
        }
    }
}
SAVED = {"result": {"count": 2, "status": "saved"}}


def cfg_v2(**env):
    return scale.Config.from_env({"RYOT_API_KEY": "key", "RYOT_URL": "http://ryot", **env})


def test_config_defaults_to_the_v2_base_and_falls_back_to_ryot_token():
    cfg = scale.Config.from_env({"RYOT_TOKEN": "legacy"})
    assert cfg.ryot_url == "http://127.0.0.1:13350"
    assert cfg.ryot_api_key == "legacy"
    both = scale.Config.from_env({"RYOT_TOKEN": "legacy", "RYOT_API_KEY": "new"})
    assert both.ryot_api_key == "new"


def test_push_logs_one_entry_with_a_reading_per_existing_metric():
    op = FakeOpener([json_reply(METRICS), json_reply(SAVED)])
    stats = [{"name": "weight", "value": "82.35"}, {"name": "bmi", "value": "24"}]
    assert scale.push_to_ryot(cfg_v2(), stats, timestamp=TS, opener=op) == TS

    lookup, log_req = op.requests
    assert lookup.full_url == "http://ryot/api/ryotql/execute"
    assert lookup.get_header("X-api-key") == "key"
    assert log_req.full_url == (
        "http://ryot/api/plugins/ryot/fitness/operations/measurement-reading-log"
    )
    assert log_req.get_header("X-api-key") == "key"
    body = op.body_of(1)
    sent = body["payload"]
    assert sent["occurredAt"] == TS
    assert sent["comment"] == "Loftilla"
    # JSON numbers, not V1's Decimal strings.
    assert sent["values"] == [
        {"metricId": "m-weight", "value": 82.35},
        {"metricId": "m-bmi", "value": 24.0},
    ]
    assert body["idempotencyKey"] == sent["submissionId"]
    assert len(sent["submissionId"]) <= 96


def test_a_retry_of_the_same_push_sends_a_byte_identical_request():
    # Ryot replays a reused idempotency key only when the payload is identical;
    # anything time-dependent in it would turn a retry into a 400.
    bodies = []
    for _ in range(2):
        op = FakeOpener([json_reply(METRICS), json_reply(SAVED)])
        scale.push_to_ryot(cfg_v2(), [{"name": "weight", "value": "82"}], timestamp=TS, opener=op)
        bodies.append(op.body_of(1))
    assert bodies[0] == bodies[1]


def test_a_different_weigh_in_gets_a_different_idempotency_key():
    a = scale.submission_id([{"name": "weight", "value": "82"}], TS)
    b = scale.submission_id([{"name": "weight", "value": "83"}], TS)
    c = scale.submission_id([{"name": "weight", "value": "82"}], "2026-08-07T00:00:00+00:00")
    assert len({a, b, c}) == 3


def test_a_missing_metric_is_created_before_logging():
    created = {"result": {"entityId": "m-fat"}}
    op = FakeOpener([json_reply(METRICS), json_reply(created), json_reply(SAVED)])
    stats = [{"name": "weight", "value": "82"}, {"name": "body_fat", "value": "18.5"}]
    scale.push_to_ryot(cfg_v2(), stats, timestamp=TS, opener=op)

    create = op.requests[1]
    assert create.full_url.endswith("/plugins/ryot/fitness/operations/measurement-metric-create")
    # Ryot derives the metric key from the name, so it must round-trip to body_fat.
    assert op.body_of(1) == {"payload": {"name": "Body Fat"}}
    assert op.body_of(2)["payload"]["values"][1] == {"metricId": "m-fat", "value": 18.5}


def test_metric_names_round_trip_to_their_keys():
    assert scale.metric_name("basal_metabolic_rate") == "Basal Metabolic Rate"
    assert scale.metric_name("bmi") == "Bmi"


def test_an_incomplete_save_is_an_error():
    op = FakeOpener([json_reply(METRICS), json_reply({"result": {"count": 1, "status": "incomplete"}})])
    with pytest.raises(RuntimeError, match="not fully saved"):
        scale.push_to_ryot(cfg_v2(), [{"name": "weight", "value": "82"}], timestamp=TS, opener=op)


def test_an_http_error_carries_ryots_reason():
    def rejected():
        raise urllib.error.HTTPError(
            "http://ryot", 422, "Unprocessable", {}, io.BytesIO(b'{"_tag":"PluginOperationRejected"}')
        )

    op = FakeOpener([json_reply(METRICS), rejected])
    with pytest.raises(RuntimeError, match="422.*PluginOperationRejected"):
        scale.push_to_ryot(cfg_v2(), [{"name": "weight", "value": "82"}], timestamp=TS, opener=op)


def test_the_v2_client_outwaits_a_cold_start():
    for fn in (ryot.api_post, ryot.ryotql, ryot.invoke_operation):
        default = inspect.signature(fn).parameters["timeout"].default
        assert default == ryot.RYOT_WAKE_TIMEOUT, fn.__name__


# ── the webhook itself ────────────────────────────────────────────────────────


@pytest.fixture
def shim():
    """A running shim with the Ryot push replaced by a recorder."""
    pushed = []

    def fake_push(stats):
        # 666 kg is the "pretend Ryot is down" trigger for the 502 path.
        if any(s["value"] == "666" for s in stats):
            raise RuntimeError("ryot down")
        pushed.append(stats)
        return "2026-08-06T00:00:00+00:00"

    cfg = scale.Config.from_env({"RYOT_API_KEY": "key", "SHIM_KEY": "secret"})
    server = ThreadingHTTPServer(
        ("127.0.0.1", 0), scale.make_handler(cfg, push=fake_push, log=lambda _: None)
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}", pushed
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def post(base, payload, key="secret", path="/measurement"):
    headers = {"Content-Type": "application/json"}
    if key is not None:
        headers["X-Shim-Key"] = key
    req = urllib.request.Request(
        base + path, data=json.dumps(payload).encode(), headers=headers, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code


def test_a_good_measurement_is_accepted_and_forwarded(shim):
    base, pushed = shim
    assert post(base, FULL_FRAME) == 200
    assert {s["name"] for s in pushed[0]} == set(scale.FIELD_MAP.values())


def test_a_wrong_or_missing_shim_key_is_rejected(shim):
    base, pushed = shim
    assert post(base, FULL_FRAME, key="wrong") == 401
    assert post(base, FULL_FRAME, key=None) == 401
    assert pushed == []


def test_a_payload_with_no_usable_statistics_is_unprocessable(shim):
    base, pushed = shim
    assert post(base, {"user_slug": "nico"}) == 422
    assert pushed == []


def test_a_ryot_failure_surfaces_as_a_bad_gateway(shim):
    base, pushed = shim
    # A 5xx (not a 200) is what tells ble-scale-sync the measurement did not land.
    assert post(base, {"weight": 666}) == 502
    assert pushed == []
    # and the shim keeps serving afterwards
    assert post(base, {"weight": 82}) == 200


def test_the_wrong_path_is_a_404(shim):
    base, _ = shim
    assert post(base, FULL_FRAME, path="/nope") == 404


def test_healthcheck_paths_answer_200(shim):
    base, _ = shim
    for path in ("/", "/health", "/measurement"):
        with urllib.request.urlopen(base + path, timeout=5) as resp:
            assert resp.status == 200


# ── main ──────────────────────────────────────────────────────────────────────


def test_main_refuses_to_start_without_a_ryot_api_key(capsys):
    assert scale.main(env={}) == 1
    assert "RYOT_API_KEY (or RYOT_TOKEN) not set" in capsys.readouterr().out


def test_main_warns_but_starts_with_no_shim_key(capsys, monkeypatch):
    served = []
    # serve() blocks forever in production; swap it for a recorder.
    monkeypatch.setattr(scale, "serve", lambda cfg, **kw: served.append(cfg))
    assert scale.main(env={"RYOT_API_KEY": "key"}) == 0
    assert "SHIM_KEY empty" in capsys.readouterr().out
    assert served and served[0].port == 8347
