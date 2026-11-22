"""pocket-id-clients: declared clients reach Pocket ID, secrets survive a reset."""

import io
import json
import urllib.error

from conftest import FakeOpener, json_reply

from nicos_scripts.security import pocket_id_clients as pic

HELD = "h" * 24  # what the service already reads
OK = json_reply({})


def not_found():
    raise urllib.error.HTTPError("u", 404, "Not Found", {}, io.BytesIO(b""))


def secret_created(sid="sec-new"):
    return json_reply({"id": sid})


def listed(*ids, prefix=HELD[:4]):
    return json_reply([{"id": i, "prefix": prefix, "isActive": True} for i in ids])


def client(tmp_path, **kw):
    c = {
        "id": "immich",
        "name": "Immich",
        "callbackURLs": ["https://rpi5:10000/auth/login"],
        "secretFile": str(tmp_path / "secrets" / "immich"),
        "idFile": str(tmp_path / "registered" / "immich"),
        "secretGroup": "immich",
    }
    c.update(kw)
    return c


def current(c, **kw):
    return json_reply({"id": c["id"], **pic.desired(c), **kw})


def secret_file(tmp_path, cid="immich"):
    return tmp_path / "secrets" / cid


def id_file(tmp_path, cid="immich"):
    return tmp_path / "registered" / cid


def hold(tmp_path, value=HELD, sid="sec-1"):
    secret_file(tmp_path).parent.mkdir(exist_ok=True)
    secret_file(tmp_path).write_text(value)
    if sid:
        id_file(tmp_path).parent.mkdir(exist_ok=True)
        id_file(tmp_path).write_text(sid)


def run(tmp_path, clients, replies, chown=lambda *a, **k: None):
    f = tmp_path / "clients.json"
    f.write_text(json.dumps(clients))
    op = FakeOpener(replies)
    lines = []
    rc = pic.main(
        env={"STATIC_API_KEY": "k" * 32, "CLIENTS_FILE": str(f)},
        opener=op,
        sleep=lambda _: None,
        chown=chown,
        log=lines.append,
    )
    return rc, op, lines


def calls(op):
    return [(r.get_method(), r.full_url.split("1411")[1]) for r in op.requests]


def test_creates_client_and_writes_a_new_secret(tmp_path):
    c = client(tmp_path)
    rc, op, _ = run(tmp_path, [c], [OK, not_found, OK, secret_created()])
    assert rc == 0
    assert calls(op) == [
        ("GET", "/healthz"),
        ("GET", "/api/oidc/clients/immich"),
        ("POST", "/api/oidc/clients"),
        ("POST", "/api/oidc/clients/immich/secrets"),
    ]
    assert op.body_of(2)["id"] == "immich" and op.body_of(2)["skipConsent"] is True
    secret = secret_file(tmp_path).read_text()
    assert len(secret) >= 32 and op.body_of(3) == {"secret": secret}
    assert id_file(tmp_path).read_text() == "sec-new"
    assert op.requests[0].headers["X-api-key"] == "k" * 32


def test_recreated_client_gets_the_secret_the_service_holds(tmp_path):
    hold(tmp_path)
    rc, op, _ = run(tmp_path, [client(tmp_path)], [OK, not_found, OK, secret_created()])
    assert rc == 0
    assert op.body_of(3) == {"secret": HELD}
    assert secret_file(tmp_path).read_text() == HELD
    assert id_file(tmp_path).read_text() == "sec-new"


def test_registered_secret_makes_no_writes(tmp_path):
    c = client(tmp_path)
    hold(tmp_path)
    rc, op, _ = run(tmp_path, [c], [OK, current(c), listed("sec-1")])
    assert rc == 0
    assert [m for m, _ in calls(op)] == ["GET", "GET", "GET"]


def test_other_secret_with_the_same_prefix_does_not_count(tmp_path):
    c = client(tmp_path)
    hold(tmp_path)
    replies = [OK, current(c), listed("sec-other"), secret_created()]
    rc, op, _ = run(tmp_path, [c], replies)
    assert rc == 0
    assert calls(op)[-1] == ("POST", "/api/oidc/clients/immich/secrets")
    assert op.body_of(-1) == {"secret": HELD}
    assert id_file(tmp_path).read_text() == "sec-new"


def test_interrupted_registration_is_retried(tmp_path):
    c = client(tmp_path)
    hold(tmp_path, sid=None)  # the POST failed before the id was recorded
    rc, op, _ = run(tmp_path, [c], [OK, current(c), secret_created()])
    assert rc == 0
    assert calls(op)[-1] == ("POST", "/api/oidc/clients/immich/secrets")
    assert op.body_of(-1) == {"secret": HELD}


def server_error():
    raise urllib.error.HTTPError("u", 500, "Internal Server Error", {}, io.BytesIO(b""))


def test_failed_post_after_recreation_is_retried_despite_a_stale_id(tmp_path):
    c = client(tmp_path)
    hold(tmp_path, sid="sec-1")  # id from before the database was reset
    rc, op, _ = run(tmp_path, [c], [OK, not_found, OK, server_error])
    assert rc == 1
    rc, op, _ = run(tmp_path, [c], [OK, current(c), listed(), secret_created()])
    assert rc == 0
    assert calls(op)[-1] == ("POST", "/api/oidc/clients/immich/secrets")
    assert op.body_of(-1) == {"secret": HELD}
    assert id_file(tmp_path).read_text() == "sec-new"


def test_update_keeps_unmanaged_fields(tmp_path):
    c = client(tmp_path, callbackURLs=["https://new/cb"])
    hold(tmp_path)
    replies = [OK, current(client(tmp_path), hasLogo=True), OK, listed("sec-1")]
    rc, op, _ = run(tmp_path, [c], replies)
    assert rc == 0
    assert calls(op)[2] == ("PUT", "/api/oidc/clients/immich")
    assert op.body_of(2)["hasLogo"] is True
    assert op.body_of(2)["callbackURLs"] == ["https://new/cb"]


def test_bad_client_does_not_stop_the_others(tmp_path):
    def chown(*a, **k):
        raise LookupError("no such group")

    a = client(tmp_path)
    b = {"name": "no id"}
    c = client(
        tmp_path,
        id="memos",
        secretFile=str(secret_file(tmp_path, "memos")),
        idFile=str(id_file(tmp_path, "memos")),
    )
    rc, op, lines = run(
        tmp_path, [a, b, c], [OK, not_found, OK, secret_created()], chown=chown
    )
    assert rc == 1
    assert sum("no such group" in line for line in lines) == 2
    assert any(line.startswith("<missing id>") for line in lines)


def test_dotted_client_id_does_not_clobber_another_secret(tmp_path):
    a = client(tmp_path)
    b = client(
        tmp_path,
        id="immich.id",
        secretFile=str(secret_file(tmp_path, "immich.id")),
        idFile=str(id_file(tmp_path, "immich.id")),
    )
    replies = [OK, not_found, OK, secret_created("sec-a"), not_found, OK]
    replies.append(secret_created("sec-b"))
    rc, _, _ = run(tmp_path, [a, b], replies)
    assert rc == 0
    assert id_file(tmp_path).read_text() == "sec-a"
    assert id_file(tmp_path, "immich.id").read_text() == "sec-b"
    assert secret_file(tmp_path).read_text() != "sec-b"
    assert len(secret_file(tmp_path).read_text()) >= 32


def test_public_client_gets_no_secret(tmp_path):
    c = client(tmp_path, isPublic=True, pkceEnabled=True)
    rc, op, _ = run(tmp_path, [c], [OK, not_found, OK])
    assert rc == 0
    assert calls(op)[-1] == ("POST", "/api/oidc/clients")
    assert not secret_file(tmp_path).exists()


def test_missing_config_is_fatal(tmp_path):
    lines = []
    assert pic.main(env={}, log=lines.append) == 1
    assert "FATAL" in lines[0]
