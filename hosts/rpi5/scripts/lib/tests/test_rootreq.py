import json
import subprocess
import threading
import time

import pytest

from conftest import FakeOpener, FakeResponse
from nicos_scripts.security import rootreq


def cfg(**kw):
    base = dict(
        socket_path="/tmp/x.sock", listen_host="100.0.0.1", listen_port=8390,
        public_url="http://rpi5.example.ts.net:8390", allowed_uid=1001,
        approver_login="me@github", approver_node="nphone.example.ts.net",
        telegram_token_file="", telegram_chat_id="42", timeout=2, run_timeout=5,
    )
    base.update(kw)
    return rootreq.Config(**base)


def whois(login="me@github", node="nphone.example.ts.net."):
    return {"UserProfile": {"LoginName": login}, "Node": {"Name": node}}


def tg_ok(message_id=7):
    return FakeResponse(json.dumps({"ok": True, "result": {"message_id": message_id}}).encode())


@pytest.fixture
def broker(tmp_path):
    tok = tmp_path / "tok"
    tok.write_text("T\n")
    opener = FakeOpener([tg_ok()])
    runs = []

    def run(argv, **kw):
        runs.append((argv, kw))
        return subprocess.CompletedProcess(argv, 3, b"out", b"err")

    b = rootreq.Broker(cfg(telegram_token_file=str(tok)), opener=opener, run=run,
                       log=lambda m: None)
    b.opener_calls, b.runs = opener, runs
    return b


def decide_when_pending(b, approve, who):
    def go():
        for _ in range(200):
            with b.lock:
                ids = list(b.pending)
            if ids and b.pending[ids[0]].message_id:
                b.result_status = b.decide(ids[0], approve, who)
                return
            time.sleep(0.01)
    t = threading.Thread(target=go)
    t.start()
    return t


def test_config_from_env_defaults_are_inert():
    c = rootreq.Config.from_env({})
    assert c.allowed_uid == -1 and c.approver_login == "" and c.timeout == 180


@pytest.mark.parametrize("req", [
    {}, {"argv": []}, {"argv": "ls"}, {"argv": ["a\0b"]}, {"argv": ["ls"], "cwd": "rel"},
    {"argv": ["x"] * 65},
])
def test_validate_rejects(req):
    with pytest.raises(ValueError):
        rootreq.validate_request(req)


def test_validate_accepts_and_defaults_cwd():
    assert rootreq.validate_request({"argv": ["ls", "-l"]}) == (["ls", "-l"], "/", "")


@pytest.mark.parametrize("w,ok", [
    (whois(), True),
    (whois(node="rpi5.example.ts.net."), False),             # the box the agents run on
    (whois(node="macbook.example.ts.net."), False),          # a host agents can SSH into
    (whois(login="someone@github"), False),
    ({}, False), (None, False),
])
def test_approver_ok_only_the_phone(w, ok):
    assert rootreq.approver_ok(w, cfg()) is ok


def test_approved_runs_argv_without_shell_and_edits_message(broker):
    t = decide_when_pending(broker, True, whois())
    res = broker.request(["systemctl", "restart", "ryot"], "/", "OOM")
    t.join()
    assert res == {"approved": True, "rc": 3, "stdout": "out", "stderr": "err"}
    argv, kw = broker.runs[0]
    assert argv == ["systemctl", "restart", "ryot"]
    assert kw["env"] == {"PATH": rootreq.RUN_PATH} and "shell" not in kw
    sent = [json.loads(r.data) for r in broker.opener_calls.requests]
    assert "sendMessage" in broker.opener_calls.requests[0].full_url
    assert sent[0]["reply_markup"]["inline_keyboard"][0][0]["url"].startswith(
        "http://rpi5.example.ts.net:8390/r/")
    assert "approved by nphone.example.ts.net" in sent[1]["text"]
    assert broker.pending == {}


def test_denied_never_runs(broker):
    t = decide_when_pending(broker, False, whois())
    res = broker.request(["rm", "-rf", "/x"], "/", "")
    t.join()
    assert res["approved"] is False and broker.runs == []


def test_decision_from_wrong_node_is_refused_and_request_expires(broker):
    t = decide_when_pending(broker, True, whois(node="rpi5.example.ts.net."))
    res = broker.request(["id"], "/", "")
    t.join()
    assert broker.result_status == 403
    assert res == {"approved": False, "error": "no decision before timeout"}
    assert broker.runs == []


def test_unknown_request_id(broker):
    assert broker.decide("nope", True, whois()) == 404


def test_execute_maps_missing_binary_and_timeout(broker):
    def missing(*a, **k):
        raise FileNotFoundError

    def slow(*a, **k):
        raise subprocess.TimeoutExpired("x", 1)

    broker.run = missing
    assert broker.execute(["nope"], "/")["rc"] == 127
    broker.run = slow
    assert broker.execute(["sleep"], "/")["rc"] == 124


def test_describe_escapes_html():
    text = rootreq.describe("id1", ["echo", "<b>"], "/", "a & b")
    assert "&lt;b&gt;" in text and "a &amp; b" in text


def test_serve_refuses_incomplete_config(capsys):
    assert rootreq.serve({}) == 2
    assert "FATAL" in capsys.readouterr().err


def _self_signed(tmp_path):
    x509 = pytest.importorskip("cryptography.x509")
    import datetime
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    k = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(x509.oid.NameOID.COMMON_NAME, "localhost")])
    now = datetime.datetime.now(datetime.timezone.utc)
    c = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(k.public_key())
         .serial_number(1).not_valid_before(now).not_valid_after(now + datetime.timedelta(days=1))
         .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False)
         .sign(k, hashes.SHA256()))
    key, cert = tmp_path / "k.pem", tmp_path / "c.pem"
    key.write_bytes(k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                    serialization.NoEncryption()))
    cert.write_bytes(c.public_bytes(serialization.Encoding.PEM))
    return key, cert


def test_tls_page_answers_over_https(tmp_path):
    import ssl
    import urllib.error
    import urllib.request
    key, cert = _self_signed(tmp_path)
    c = cfg(listen_host="127.0.0.1", tls_cert=str(cert), tls_key=str(key))
    http = rootreq._HttpServer(("127.0.0.1", 0), rootreq.make_http_handler(rootreq.Broker(c), lambda ip: None))
    http.tls = rootreq.tls_context(c)
    threading.Thread(target=http.serve_forever, daemon=True).start()
    try:
        ctx = ssl.create_default_context(cafile=str(cert))
        with pytest.raises(urllib.error.HTTPError) as e:
            urllib.request.urlopen(f"https://localhost:{http.server_port}/r/nope", context=ctx, timeout=5)
        assert e.value.code == 404
    finally:
        http.shutdown()
