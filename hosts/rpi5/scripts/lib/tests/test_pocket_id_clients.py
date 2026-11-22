"""pocket-id-clients: declared clients reach Pocket ID, secrets survive a reset."""

import io
import json
import urllib.error

from conftest import FakeOpener, json_reply

from nicos_scripts.security import pocket_id_clients as pic


HELD = "h" * 24  # what the service already reads


def not_found():
    raise urllib.error.HTTPError("u", 404, "Not Found", {}, io.BytesIO(b""))


def client(tmp_path, **kw):
    c = {
        "id": "immich",
        "name": "Immich",
        "callbackURLs": ["https://rpi5:10000/auth/login"],
        "secretFile": str(tmp_path / "immich"),
        "secretGroup": "immich",
    }
    c.update(kw)
    return c


def run(tmp_path, clients, replies):
    f = tmp_path / "clients.json"
    f.write_text(json.dumps(clients))
    op = FakeOpener(replies)
    lines = []
    rc = pic.main(
        env={"STATIC_API_KEY": "k" * 32, "CLIENTS_FILE": str(f)},
        opener=op,
        sleep=lambda _: None,
        chown=lambda *a, **k: None,
        log=lines.append,
    )
    return rc, op, lines


def calls(op):
    return [(r.get_method(), r.full_url.split("1411")[1]) for r in op.requests]


def test_creates_client_and_writes_a_new_secret(tmp_path):
    c = client(tmp_path)
    rc, op, _ = run(tmp_path, [c], [json_reply({}), not_found, json_reply({})])
    assert rc == 0
    assert calls(op) == [
        ("GET", "/healthz"),
        ("GET", "/api/oidc/clients/immich"),
        ("POST", "/api/oidc/clients"),
        ("POST", "/api/oidc/clients/immich/secrets"),
    ]
    assert op.body_of(2)["id"] == "immich" and op.body_of(2)["skipConsent"] is True
    secret = (tmp_path / "immich").read_text()
    assert len(secret) >= 32 and op.body_of(3) == {"secret": secret}
    assert op.requests[0].headers["X-api-key"] == "k" * 32


def test_recreated_client_gets_the_secret_the_service_holds(tmp_path):
    (tmp_path / "immich").write_text(HELD)
    rc, op, _ = run(
        tmp_path, [client(tmp_path)], [json_reply({}), not_found, json_reply({})]
    )
    assert rc == 0
    assert op.body_of(3) == {"secret": HELD}
    assert (tmp_path / "immich").read_text() == HELD


def test_unchanged_client_with_secret_makes_no_writes(tmp_path):
    c = client(tmp_path)
    (tmp_path / "immich").write_text("s" * 40)
    current = {"id": "immich", "hasLogo": True, **pic.desired(c)}
    rc, op, _ = run(tmp_path, [c], [json_reply({}), json_reply(current)])
    assert rc == 0
    assert [m for m, _ in calls(op)] == ["GET", "GET"]


def test_update_keeps_unmanaged_fields(tmp_path):
    c = client(tmp_path, callbackURLs=["https://new/cb"])
    (tmp_path / "immich").write_text("s" * 40)
    current = {"id": "immich", "hasLogo": True, **pic.desired(client(tmp_path))}
    rc, op, _ = run(
        tmp_path, [c], [json_reply({}), json_reply(current), json_reply({})]
    )
    assert rc == 0
    assert calls(op)[-1] == ("PUT", "/api/oidc/clients/immich")
    assert op.body_of(-1)["hasLogo"] is True
    assert op.body_of(-1)["callbackURLs"] == ["https://new/cb"]


def test_public_client_gets_no_secret(tmp_path):
    c = client(tmp_path, isPublic=True, pkceEnabled=True)
    rc, op, _ = run(tmp_path, [c], [json_reply({}), not_found, json_reply({})])
    assert rc == 0
    assert calls(op)[-1] == ("POST", "/api/oidc/clients")
    assert not (tmp_path / "immich").exists()


def test_missing_config_is_fatal(tmp_path):
    lines = []
    assert pic.main(env={}, log=lines.append) == 1
    assert "FATAL" in lines[0]
