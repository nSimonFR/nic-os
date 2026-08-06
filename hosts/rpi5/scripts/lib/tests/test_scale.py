"""scale-to-ryot: the QN payload translation and the webhook's contract.

The handler tests run a real ThreadingHTTPServer on an ephemeral port with the
Ryot push replaced by a recorder — the shim's whole job is HTTP status codes, and
those are only worth testing against a real socket.
"""

import json
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import pytest
from conftest import FakeOpener, json_reply

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


def test_every_mapped_field_is_translated_to_its_ryot_name():
    stats = {s["name"]: s["value"] for s in scale.build_statistics(FULL_FRAME)}
    assert stats["body_fat"] == "18.5"
    assert stats["basal_metabolic_rate"] == "1785"
    assert set(stats) == set(scale.FIELD_MAP.values())


def test_zeros_are_dropped_except_weight():
    # QN scales emit 0 for body-comp fields on the weight-only frame (before
    # impedance settles); pushing those would overwrite a good measurement.
    stats = scale.build_statistics({"weight": 82.0, "bodyFatPercent": 0, "bmi": 0})
    assert stats == [{"name": "weight", "value": "82"}]


def test_a_zero_weight_is_still_reported():
    assert scale.build_statistics({"weight": 0}) == [{"name": "weight", "value": "0"}]


def test_absent_and_non_numeric_fields_are_skipped():
    stats = scale.build_statistics({"weight": "82.35", "bmi": "n/a", "muscleMass": None})
    assert stats == [{"name": "weight", "value": "82.35"}]


def test_unknown_fields_are_ignored():
    assert scale.build_statistics({"user_slug": "nico", "battery": 99}) == []


def test_values_are_formatted_as_trimmed_decimal_strings():
    # Ryot's Decimal takes a string; %g drops the trailing .0 noise.
    stats = scale.build_statistics({"weight": 82.50, "bmi": 24.000})
    assert stats == [
        {"name": "weight", "value": "82.5"},
        {"name": "bmi", "value": "24"},
    ]


# ── push_to_ryot ──────────────────────────────────────────────────────────────


def test_push_sends_the_mutation_with_the_measurement_name_and_timestamp():
    cfg = scale.Config.from_env({"RYOT_TOKEN": "tok", "MEASUREMENT_NAME": "Loftilla"})
    op = FakeOpener([json_reply({"data": {"createOrUpdateUserMeasurement": "2026-08-06"}})])
    out = scale.push_to_ryot(
        cfg, [{"name": "weight", "value": "82"}], timestamp="2026-08-06T00:00:00+00:00", opener=op
    )
    assert out == "2026-08-06"
    body = op.body_of()
    assert body["query"] == scale.MUTATION
    sent = body["variables"]["i"]
    assert sent["name"] == "Loftilla"
    assert sent["timestamp"] == "2026-08-06T00:00:00+00:00"
    assert sent["information"]["statistics"] == [{"name": "weight", "value": "82"}]
    # Ryot rejects the input unless all four asset lists are present.
    assert sent["information"]["assets"] == {
        "s3Images": [],
        "s3Videos": [],
        "remoteImages": [],
        "remoteVideos": [],
    }


def test_push_raises_on_a_graphql_error_inside_a_200():
    cfg = scale.Config.from_env({"RYOT_TOKEN": "tok"})
    op = FakeOpener([json_reply({"errors": [{"message": "bad token"}]})])
    with pytest.raises(RuntimeError):
        scale.push_to_ryot(cfg, [], opener=op)


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

    cfg = scale.Config.from_env({"RYOT_TOKEN": "tok", "SHIM_KEY": "secret"})
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


def test_main_refuses_to_start_without_a_ryot_token(capsys):
    assert scale.main(env={}) == 1
    assert "RYOT_TOKEN not set" in capsys.readouterr().out


def test_main_warns_but_starts_with_no_shim_key(capsys, monkeypatch):
    served = []
    # serve() blocks forever in production; swap it for a recorder.
    monkeypatch.setattr(scale, "serve", lambda cfg, **kw: served.append(cfg))
    assert scale.main(env={"RYOT_TOKEN": "tok"}) == 0
    assert "SHIM_KEY empty" in capsys.readouterr().out
    assert served and served[0].port == 8347
