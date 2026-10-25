"""ryot-bootstrap: keep a working V2 API key without needless password resets."""

import json
from email.message import Message

from conftest import FakeOpener, FakeResponse, json_reply

from nicos_scripts.connectors import ryot_bootstrap as rb

ENV = {"RYOT_FRONTEND_URL": "https://ryot.example:3710", "SERVER_ADMIN_ACCESS_TOKEN": "adm"}


def cfg(tmp_path):
    return rb.Config.from_env({**ENV, "SECRETS_DIR": str(tmp_path)})


def signed_in(cookie="__Secure-better-auth.session_token=abc"):
    def reply():
        r = FakeResponse(json.dumps({"user": {}}).encode(), 200)
        r.headers = Message()
        r.headers["Set-Cookie"] = f"{cookie}; Path=/; HttpOnly"
        return r
    return reply


def no_write_group(path, text, group=None, mode=0o600):
    rb.write_secret(path, text, None, mode)


def run_user_lookup(argv):
    assert "postgres" in argv and "ryotv2" in argv
    return "usr_1\n"


def test_a_working_key_is_left_alone(tmp_path):
    c = cfg(tmp_path)
    c.key_file.write_text("k1\n")
    op = FakeOpener([json_reply({"_tag": "RyotQLBadRequest"}, 400)])
    assert rb.ensure_key(c, run_user_lookup, opener=op) == "kept"
    assert len(op.requests) == 1
    assert op.last.get_header("X-api-key") == "k1"


def test_a_stored_password_is_reused_instead_of_resetting(tmp_path):
    # A reset would delete every existing API key of the user.
    c = cfg(tmp_path)
    c.password_file.write_text("pw\n")
    op = FakeOpener([signed_in(), json_reply({"key": "k2"})])
    assert rb.ensure_key(c, run_user_lookup, opener=op, write=no_write_group) == "created"
    paths = [r.full_url.split(":13350")[1] for r in op.requests]
    assert paths == ["/api/auth/sign-in/email", "/api/auth/api-key/create"]
    assert op.requests[1].get_header("Cookie").startswith("__Secure-better-auth.session_token=")
    assert c.key_file.read_text() == "k2\n"
    assert c.env_file.read_text() == "RYOT_API_KEY=k2\n"


def test_first_run_resets_the_password_through_the_admin_api(tmp_path):
    c = cfg(tmp_path)
    op = FakeOpener([
        json_reply({"email": "nsimon@ryot.local",
                    "resetUrl": "https://ryot.example:3710/reset-password?token=t0k"}),
        json_reply({"status": True}),
        signed_in(),
        json_reply({"key": "k3"}),
    ])
    rb.ensure_key(c, run_user_lookup, opener=op, new_password="newpw", write=no_write_group)
    assert op.requests[0].full_url.endswith("/api/instance-admin/users/usr_1/reset-password")
    assert op.requests[0].get_header("Admin-access-token") == "adm"
    assert op.body_of(1) == {"newPassword": "newpw", "token": "t0k"}
    assert op.requests[1].get_header("Origin") == "https://ryot.example:3710"
    assert c.password_file.read_text() == "newpw\n"
    assert c.key_file.read_text() == "k3\n"


def test_secrets_are_not_world_readable(tmp_path):
    c = cfg(tmp_path)
    c.password_file.write_text("pw\n")
    rb.ensure_key(c, run_user_lookup, opener=FakeOpener([signed_in(), json_reply({"key": "k"})]),
                  write=no_write_group)
    assert c.key_file.stat().st_mode & 0o007 == 0
    assert c.env_file.stat().st_mode & 0o007 == 0


def test_main_fails_without_the_admin_token(capsys):
    assert rb.main(env={"RYOT_FRONTEND_URL": "x"}) == 1
    assert "missing env" in capsys.readouterr().out


def test_main_reports_a_failed_reset(tmp_path, capsys):
    op = FakeOpener([json_reply({"status": "ok"}), json_reply({"_tag": "AuthUnauthorized"}, 401)])
    env = {**ENV, "SECRETS_DIR": str(tmp_path)}
    assert rb.main(env=env, run=run_user_lookup, opener=op, sleep=lambda s: None) == 1
    assert "reset-password failed (401)" in capsys.readouterr().out


def test_main_waits_for_ryot_to_finish_migrating(tmp_path, capsys):
    down = lambda: (_ for _ in ()).throw(rb.urllib.error.URLError("refused"))
    op = FakeOpener([down, down, json_reply({"status": "ok"}), signed_in(), json_reply({"key": "k"})])
    (tmp_path / "password").write_text("pw\n")
    env = {**ENV, "SECRETS_DIR": str(tmp_path), "SECRETS_GROUP": ""}
    slept = []
    assert rb.main(env=env, run=run_user_lookup, opener=op, sleep=slept.append) == 0
    assert len(slept) == 2


def test_main_gives_up_when_ryot_never_comes_up(tmp_path, capsys):
    op = FakeOpener([json_reply({}, 503)])
    env = {**ENV, "SECRETS_DIR": str(tmp_path)}
    assert rb.main(env=env, run=run_user_lookup, opener=op, sleep=lambda s: None) == 1
    assert "not healthy" in capsys.readouterr().out
