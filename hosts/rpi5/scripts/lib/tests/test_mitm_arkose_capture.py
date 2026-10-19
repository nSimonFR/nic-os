import json
from types import SimpleNamespace

from nicos_scripts.mitm import arkose_capture as mod


def test_decode_raw_ddp():
    assert mod.decode_frame('{"msg":"sub","name":"_boulders.list"}') == [{"msg": "sub", "name": "_boulders.list"}]


def test_decode_sockjs_frames():
    assert mod.decode_frame("o") == []
    assert mod.decode_frame("h") == []
    assert mod.decode_frame('a["{\\"msg\\":\\"ready\\",\\"subs\\":[\\"1\\"]}"]') == [{"msg": "ready", "subs": ["1"]}]
    assert mod.decode_frame('["{\\"msg\\":\\"connect\\"}","{\\"msg\\":\\"ping\\"}"]') == [{"msg": "connect"}, {"msg": "ping"}]


def test_redacts_login_secrets_at_any_depth():
    m = {"msg": "method", "method": "login",
         "params": [{"user": {"email": "a@b"}, "password": {"digest": "d", "algorithm": "sha-256"}}]}
    assert mod.redact(m)["params"][0] == {"user": {"email": "a@b"}, "password": "<redacted>"}
    assert mod.redact({"msg": "result", "result": {"id": "u", "token": "t"}})["result"] == {"id": "u", "token": "<redacted>"}
    assert mod.redact([{"resume": "t"}]) == [{"resume": "<redacted>"}]


def ws_flow(host, text, from_client=True):
    msg = SimpleNamespace(text=text, content=text.encode(), is_text=True, from_client=from_client)
    return SimpleNamespace(request=SimpleNamespace(pretty_host=host, method="GET", path="/sockjs/1/x/websocket"),
                           websocket=SimpleNamespace(messages=[msg]))


def lines(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def test_websocket_frame_logged_redacted(tmp_path):
    out = tmp_path / "c.jsonl"
    cap = mod.ArkoseCapture(str(out), clock=lambda: 1.0)
    cap.websocket_message(ws_flow("plus.arkose.com", '["{\\"msg\\":\\"method\\",\\"method\\":\\"login\\",\\"params\\":[{\\"resume\\":\\"secret\\"}],\\"id\\":\\"1\\"}"]'))
    cap.websocket_message(ws_flow("plus.arkose.com", 'a["{\\"msg\\":\\"added\\",\\"collection\\":\\"sessions\\",\\"id\\":\\"s\\"}"]', from_client=False))
    cap.websocket_message(ws_flow("plus.arkose.com", "h", from_client=False))
    recs = lines(out)
    assert len(recs) == 2
    assert recs[0]["dir"] == "c2s" and recs[0]["ddp"][0]["params"] == [{"resume": "<redacted>"}]
    assert "secret" not in out.read_text()
    assert recs[1] == {"ts": 1.0, "kind": "ws", "host": "plus.arkose.com", "dir": "s2c",
                       "ddp": [{"msg": "added", "collection": "sessions", "id": "s"}]}


def test_http_request_logged_without_query(tmp_path):
    out = tmp_path / "c.jsonl"
    flow = SimpleNamespace(request=SimpleNamespace(pretty_host="www.sboulder.com", method="GET", path="/arkose/stats?token=x"))
    mod.ArkoseCapture(str(out), clock=lambda: 2.0).request(flow)
    assert lines(out) == [{"ts": 2.0, "kind": "http", "host": "www.sboulder.com", "method": "GET", "path": "/arkose/stats"}]


def test_other_hosts_ignored(tmp_path):
    out = tmp_path / "c.jsonl"
    cap = mod.ArkoseCapture(str(out))
    cap.websocket_message(ws_flow("other.galaxycloud.app", '{"msg":"sub"}'))
    cap.request(SimpleNamespace(request=SimpleNamespace(pretty_host="other.galaxycloud.app", method="GET", path="/")))
    assert not out.exists()
