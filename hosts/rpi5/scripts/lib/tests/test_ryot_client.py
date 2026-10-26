"""Client.operation: a stored "sandbox never started" failure must not pin a key."""

import io
import urllib.error

import pytest
from conftest import FakeOpener, json_reply

from nicos_scripts import ryot

STARTUP_FAILED = (
    '{"_tag":"PluginInvocationError","reason":{"code":"runtime-failed","diagnostics":'
    '[{"phase":"execute","message":"Sandbox sidecar startup failed"}]}}'
)


def http_error(code, body):
    return lambda: (_ for _ in ()).throw(
        urllib.error.HTTPError("http://ryot", code, "err", {}, io.BytesIO(body.encode()))
    )


def client(op):
    return ryot.Client("http://ryot", "k", opener=op, sleep=lambda s: None)


def test_a_startup_failure_retries_once_under_a_new_key():
    op = FakeOpener([http_error(502, STARTUP_FAILED), json_reply({"result": {"status": "saved"}})])
    assert client(op).operation("ryot/media", "media-activity-log", {"a": 1}, "sub1") == {
        "status": "saved"
    }
    first, second = op.body_of(0), op.body_of(1)
    assert first["idempotencyKey"] == "sub1"
    assert second["idempotencyKey"].startswith("sub1~")
    assert second["payload"] == first["payload"]


def test_other_failures_keep_the_key_and_raise():
    op = FakeOpener([http_error(502, '{"message":"boom"}')])
    with pytest.raises(RuntimeError, match="502"):
        client(op).operation("ryot/media", "media-activity-log", {}, "sub1")
    assert len(op.requests) == 1


def test_without_a_key_a_startup_failure_is_not_retried():
    op = FakeOpener([http_error(502, STARTUP_FAILED)])
    with pytest.raises(RuntimeError):
        client(op).operation("ryot/media", "media-activity-log", {})
    assert len(op.requests) == 1
