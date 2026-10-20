import json
from types import SimpleNamespace

from nicos_scripts.mitm import arkose as mod


def test_decode_raw_ddp():
    assert mod.decode_frame('{"msg":"sub","name":"_boulders.list"}') == [{"msg": "sub", "name": "_boulders.list"}]


def test_decode_sockjs_frames():
    assert mod.decode_frame("o") == []
    assert mod.decode_frame("h") == []
    assert mod.decode_frame('a["{\\"msg\\":\\"ready\\",\\"subs\\":[\\"1\\"]}"]') == [{"msg": "ready", "subs": ["1"]}]
    assert mod.decode_frame('["{\\"msg\\":\\"connect\\"}","{\\"msg\\":\\"ping\\"}"]') == [{"msg": "connect"}, {"msg": "ping"}]


def ws_flow(text, from_client, host="plus.arkose.com", flow_id="f1"):
    msg = SimpleNamespace(text=text, content=text.encode(), is_text=True, from_client=from_client)
    return SimpleNamespace(id=flow_id, request=SimpleNamespace(pretty_host=host),
                           websocket=SimpleNamespace(messages=[msg]))


LOGIN = json.dumps({"msg": "method", "method": "login", "params": [{"resume": "old"}], "id": "1"})
OK = json.dumps({"msg": "result", "id": "1", "result": {"id": "U1", "token": "T1", "type": "resume"}})


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


def test_accepted_login_writes_token(tmp_path):
    out = tmp_path / "token.json"
    addon = mod.ArkoseToken(str(out), clock=Clock())
    addon.websocket_message(ws_flow(LOGIN, True))
    addon.websocket_message(ws_flow(OK, False))
    assert json.loads(out.read_text()) == {"userId": "U1", "token": "T1", "capturedAt": 1000.0}
    assert out.stat().st_mode & 0o777 == 0o644
    assert not addon.pending


def test_refused_login_and_unrelated_results_write_nothing(tmp_path):
    out = tmp_path / "token.json"
    addon = mod.ArkoseToken(str(out), clock=Clock())
    addon.websocket_message(ws_flow(LOGIN, True))
    addon.websocket_message(ws_flow(json.dumps({"msg": "result", "id": "1", "error": {"error": 403}}), False))
    # A token-shaped result for a call that was not a login.
    addon.websocket_message(ws_flow(OK, False))
    # A login on another connection with the same DDP id.
    addon.websocket_message(ws_flow(LOGIN, True, flow_id="f2"))
    addon.websocket_message(ws_flow(OK, False, flow_id="f1"))
    assert not out.exists()


def test_rewrite_is_debounced_unless_token_changes(tmp_path):
    out = tmp_path / "token.json"
    clock = Clock()
    addon = mod.ArkoseToken(str(out), clock=clock)

    def login(result):
        addon.websocket_message(ws_flow(LOGIN, True))
        addon.websocket_message(ws_flow(json.dumps({"msg": "result", "id": "1", "result": result}), False))

    login({"id": "U1", "token": "T1"})
    clock.t += 60
    login({"id": "U1", "token": "T1"})
    assert json.loads(out.read_text())["capturedAt"] == 1000.0
    login({"id": "U1", "token": "T2"})
    assert json.loads(out.read_text()) == {"userId": "U1", "token": "T2", "capturedAt": 1060.0}
    clock.t += mod.MIN_REWRITE_S
    login({"id": "U1", "token": "T2"})
    assert json.loads(out.read_text())["capturedAt"] == 1660.0


def test_other_hosts_ignored(tmp_path):
    out = tmp_path / "token.json"
    addon = mod.ArkoseToken(str(out), clock=Clock())
    addon.websocket_message(ws_flow(LOGIN, True, host="example.galaxycloud.app"))
    addon.websocket_message(ws_flow(OK, False, host="example.galaxycloud.app"))
    assert not out.exists()
