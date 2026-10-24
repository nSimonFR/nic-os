"""The bridge must never lock the grantee account out, never act while the switch
is quiet, and must hand the contacts a password that actually opens the account.
The fake server below checks hashes and unwraps keys the way Vaultwarden does.
"""

import io
import json
import os
import urllib.error
import urllib.parse

import pytest

from conftest import FakeResponse
from nicos_scripts.vaultwarden import bwcrypto
from nicos_scripts.vaultwarden import ea_bridge as eb

GRANTEE = "heir@example.com"
GRANTOR = "owner@example.com"
KDF = {"type": bwcrypto.PBKDF2, "iterations": 1000, "memory": None, "parallelism": None}
USER_KEY = bytes(range(64))


def wrap(password, user_key=USER_KEY):
    mkey = bwcrypto.master_key(password, GRANTEE, KDF)
    return bwcrypto.password_hash(mkey, password), bwcrypto.encrypt(user_key, *bwcrypto.stretch(mkey))


class FakeServer:
    """urlopen-compatible Vaultwarden: prelogin, token, EA, devices, password."""

    def __init__(self, password, status=eb.EA_CONFIRMED, devices=None, ciphers=()):
        self.hash, self.akey = wrap(password)
        self.ea = {"id": "ea1", "status": status, "waitTimeDays": 3, "email": GRANTOR}
        self.devices = devices if devices is not None else [{"identifier": eb.DEVICE_ID, "name": eb.TAG}]
        self.ciphers = list(ciphers)
        self.calls = []
        self.fail_password_change = False

    def __call__(self, req, timeout=None):
        path = urllib.parse.urlparse(req.full_url).path.removeprefix("/vw")
        self.calls.append((req.get_method(), path))
        body = req.data or b""
        if path == "/identity/accounts/prelogin":
            return self.reply({"kdf": 0, "kdfIterations": KDF["iterations"]})
        if path == "/identity/connect/token":
            form = dict(urllib.parse.parse_qsl(body.decode()))
            if form["password"] != self.hash or form["device_identifier"] != eb.DEVICE_ID:
                raise self.error(req, 400)
            return self.reply({"access_token": "tok", "Key": self.akey})
        if req.get_header("Authorization") != "Bearer tok":
            raise self.error(req, 401)
        if path == "/api/emergency-access/granted":
            return self.reply({"data": [self.ea]})
        if path == "/api/emergency-access/ea1/initiate":
            assert self.ea["status"] == eb.EA_CONFIRMED
            self.ea["status"] = eb.EA_INITIATED
            return self.reply(self.ea)
        if path == "/api/devices":
            return self.reply({"data": self.devices})
        if path == "/api/ciphers":
            return self.reply({"data": self.ciphers})
        if path == "/api/accounts/password":
            data = json.loads(body)
            if data["masterPasswordHash"] != self.hash:
                raise self.error(req, 400)
            self.hash, self.akey = data["newMasterPasswordHash"], data["key"]
            if self.fail_password_change:
                raise self.error(req, 502)
            return self.reply({})
        raise self.error(req, 404)

    @staticmethod
    def reply(obj):
        return FakeResponse(json.dumps(obj).encode())

    @staticmethod
    def error(req, code):
        return urllib.error.HTTPError(req.full_url, code, "x", {}, io.BytesIO(b""))

    def opens_with(self, password):
        try:
            eb.Vault(cfg_for(None), self).login(GRANTEE, password)
            return True
        except eb.VaultError:
            return False


def cfg_for(tmp, **kw):
    base = dict(switch_dir=str(tmp and tmp / "switch"), state_dir=str(tmp and tmp / "state"),
                vault_url="http://vw/vw", public_url="https://pub/vaultwarden",
                grantee=GRANTEE, grantor=GRANTOR, dry_run=False)
    base.update(kw)
    return eb.Config(**base)


@pytest.fixture
def world(tmp_path):
    (tmp_path / "switch").mkdir()
    (tmp_path / "state").mkdir()

    def write_switch(cycle):
        (tmp_path / "switch" / "state.json").write_text(json.dumps({"cycle": cycle}))

    (tmp_path / "switch" / "config.json").write_text(json.dumps(
        {"owner_name": "Owner", "timezone": "Europe/Paris"}))
    (tmp_path / "switch" / "contacts.json").write_text(json.dumps({"contacts": [
        {"id": "c1", "name": "Mum", "email": "mum@example.com"},
        {"id": "c2", "name": "Dad", "email": "dad@example.com"},
    ]}))
    (tmp_path / "state" / "state.json").write_text(json.dumps(
        {"password": "old-pass", "pending": None, "fire": None}))
    write_switch(None)
    return tmp_path, write_switch


def state_of(tmp):
    return json.loads((tmp / "state" / "state.json").read_text())


def go(tmp, server, cmd="run", mails=None, **kw):
    lines = []
    send = (lambda to, subj, body: mails.append((to, body))) if mails is not None else (lambda *a: None)
    env = {"SWITCH_DIR": str(tmp / "switch"), "STATE_DIR": str(tmp / "state"),
           "VAULT_URL": "http://vw/vw", "PUBLIC_URL": "https://pub/vaultwarden",
           "GRANTEE_EMAIL": GRANTEE, "GRANTOR_EMAIL": GRANTOR, "DRY_RUN": "0"}
    env.update(kw)
    rc = eb.main([cmd], env=env, opener=server, send=send, log=lines.append)
    return rc, lines


FIRED = {"stage": "fired", "fired_at": 1000, "notified": {"c1": 1001}}


# ── crypto ───────────────────────────────────────────────────────────────────

def test_encstring_round_trips():
    enc, mac = bwcrypto.stretch(b"k" * 32)
    assert bwcrypto.decrypt(bwcrypto.encrypt(USER_KEY, enc, mac), enc, mac) == USER_KEY


def test_a_wrong_key_is_refused_not_garbled():
    enc, mac = bwcrypto.stretch(b"k" * 32)
    s = bwcrypto.encrypt(USER_KEY, enc, mac)
    with pytest.raises(ValueError):
        bwcrypto.decrypt(s, *bwcrypto.stretch(b"x" * 32))


def test_master_key_salts_with_the_normalised_email():
    a = bwcrypto.master_key("pw", " Heir@Example.com ", KDF)
    assert a == bwcrypto.master_key("pw", "heir@example.com", KDF)


def test_argon2id_master_key_is_deterministic():
    kdf = {"type": bwcrypto.ARGON2ID, "iterations": 1, "memory": 1, "parallelism": 1}
    assert bwcrypto.master_key("pw", GRANTEE, kdf) == bwcrypto.master_key("pw", GRANTEE, kdf)


# ── quiet switch ─────────────────────────────────────────────────────────────

def test_a_quiet_switch_never_touches_vaultwarden(world):
    tmp, write = world
    write({"stage": "checkin"})
    server = FakeServer("old-pass")
    assert go(tmp, server)[0] == 0
    assert server.calls == []


def test_an_unreadable_switch_state_fails_loudly(world):
    tmp, _ = world
    (tmp / "switch" / "state.json").unlink()
    assert go(tmp, FakeServer("old-pass"))[0] == 1


# ── firing ───────────────────────────────────────────────────────────────────

def test_firing_requests_access_rotates_and_mails_the_working_password(world):
    tmp, write = world
    write(FIRED)
    server, mails = FakeServer("old-pass"), []
    assert go(tmp, server, mails=mails)[0] == 0

    assert server.ea["status"] == eb.EA_INITIATED
    new = state_of(tmp)["password"]
    assert new != "old-pass" and server.opens_with(new) and not server.opens_with("old-pass")
    assert [to for to, _ in mails] == ["mum@example.com"]
    assert new in mails[0][1] and GRANTEE in mails[0][1] and "https://pub/vaultwarden" in mails[0][1]


def test_contacts_reached_later_get_the_same_password_once(world):
    tmp, write = world
    write(FIRED)
    server, mails = FakeServer("old-pass"), []
    go(tmp, server, mails=mails)
    write({**FIRED, "notified": {"c1": 1001, "c2": 1500}})
    go(tmp, server, mails=mails)
    go(tmp, server, mails=mails)

    assert [to for to, _ in mails] == ["mum@example.com", "dad@example.com"]
    assert mails[0][1] == mails[1][1].replace("Dad", "Mum")
    assert server.calls.count(("POST", "/api/accounts/password")) == 1
    assert server.calls.count(("POST", "/api/emergency-access/ea1/initiate")) == 1


def test_an_already_running_request_is_left_alone(world):
    tmp, write = world
    write(FIRED)
    server = FakeServer("old-pass", status=eb.EA_INITIATED)
    assert go(tmp, server)[0] == 0
    assert ("POST", "/api/emergency-access/ea1/initiate") not in server.calls


def test_a_revoked_access_fails_instead_of_mailing(world):
    tmp, write = world
    write(FIRED)
    server, mails = FakeServer("old-pass", status=0), []
    assert go(tmp, server, mails=mails)[0] == 1
    assert mails == []


def test_a_rotation_cut_off_mid_call_is_recovered(world):
    """The server took the new password but the reply was lost."""
    tmp, write = world
    write(FIRED)
    server = FakeServer("old-pass")
    server.fail_password_change = True
    assert go(tmp, server)[0] == 1
    pending = state_of(tmp)["pending"]
    assert server.opens_with(pending)

    server.fail_password_change = False
    mails = []
    assert go(tmp, server, mails=mails)[0] == 0
    password = state_of(tmp)["password"]
    assert server.opens_with(password) and password in mails[0][1]


def test_dry_run_changes_nothing(world):
    tmp, write = world
    write(FIRED)
    server, mails = FakeServer("old-pass"), []
    assert go(tmp, server, mails=mails, DRY_RUN="1")[0] == 0
    assert server.ea["status"] == eb.EA_CONFIRMED and server.opens_with("old-pass")
    assert mails == [] and state_of(tmp)["fire"] is None


def test_dry_run_is_the_default():
    assert eb.Config.from_env({}).dry_run is True


# ── {vault_access} hook ──────────────────────────────────────────────────────

def hook(tmp, server, contact="c1"):
    printed = []
    rc = eb.main(["access", contact], env={
        "SWITCH_DIR": str(tmp / "switch"), "STATE_DIR": str(tmp / "state"),
        "VAULT_URL": "http://vw/vw", "PUBLIC_URL": "https://pub/vaultwarden",
        "GRANTEE_EMAIL": GRANTEE, "GRANTOR_EMAIL": GRANTOR, "DRY_RUN": "0"},
        opener=server, log=lambda m: None, out=printed.append)
    return rc, "\n".join(printed)


def test_the_hook_puts_a_working_password_in_the_switch_message(world):
    tmp, write = world
    write({"stage": "fired", "fired_at": 1000, "notified": {}})
    server = FakeServer("old-pass")
    rc, block = hook(tmp, server)
    password = state_of(tmp)["password"]
    assert rc == 0 and server.ea["status"] == eb.EA_INITIATED
    assert password in block and GRANTEE in block and "https://pub/vaultwarden" in block
    assert server.opens_with(password) and not server.opens_with("old-pass")


def test_every_contact_gets_the_same_password_from_one_rotation(world):
    tmp, write = world
    write({"stage": "fired", "fired_at": 1000, "notified": {}})
    server = FakeServer("old-pass")
    _, first = hook(tmp, server, "c1")
    _, second = hook(tmp, server, "c2")
    assert first == second
    assert server.calls.count(("POST", "/api/accounts/password")) == 1


def test_no_separate_mail_for_a_contact_whose_message_carried_it(world):
    tmp, write = world
    write({"stage": "fired", "fired_at": 1000, "notified": {}})
    server, mails = FakeServer("old-pass"), []
    hook(tmp, server, "c1")
    write({"stage": "fired", "fired_at": 1000, "notified": {"c1": 1001, "c2": 1002}})
    go(tmp, server, mails=mails)
    assert [to for to, _ in mails] == ["dad@example.com"]


def test_the_hook_refuses_before_a_firing(world):
    tmp, write = world
    write({"stage": "checkin"})
    server = FakeServer("old-pass")
    rc, block = hook(tmp, server)
    assert rc == 1 and block == "" and server.calls == []


def test_a_failing_hook_prints_nothing_so_the_switch_uses_its_fallback(world):
    tmp, write = world
    write({"stage": "fired", "fired_at": 1000, "notified": {}})
    rc, block = hook(tmp, FakeServer("someone-changed-it"))
    assert rc == 1 and block == ""


# ── false alarm ──────────────────────────────────────────────────────────────

def test_a_check_in_after_firing_kills_the_mailed_password(world):
    tmp, write = world
    write(FIRED)
    server, mails = FakeServer("old-pass"), []
    go(tmp, server, mails=mails)
    mailed = state_of(tmp)["password"]

    write(None)
    assert go(tmp, server)[0] == 0
    assert not server.opens_with(mailed)
    assert server.opens_with(state_of(tmp)["password"])
    assert state_of(tmp)["fire"] is None


def test_a_second_firing_starts_over(world):
    tmp, write = world
    write(FIRED)
    server, mails = FakeServer("old-pass"), []
    go(tmp, server, mails=mails)
    write(None)
    go(tmp, server)
    server.ea["status"] = eb.EA_CONFIRMED  # the owner rejected the first request
    write({**FIRED, "fired_at": 9000})
    go(tmp, server, mails=mails)
    assert len(mails) == 2 and server.ea["status"] == eb.EA_INITIATED
    assert server.opens_with(state_of(tmp)["password"])


# ── health check ─────────────────────────────────────────────────────────────

def test_check_passes_on_a_clean_setup(world):
    tmp, _ = world
    assert go(tmp, FakeServer("old-pass"), "check")[0] == 0


@pytest.mark.parametrize("server", [
    FakeServer("someone-changed-it"),
    FakeServer("old-pass", status=0),
    FakeServer("old-pass", devices=[{"identifier": "phone", "name": "iPhone"}]),
    FakeServer("old-pass", ciphers=[{"id": "x"}]),
])
def test_check_flags_anything_that_would_break_or_betray_the_bridge(world, server):
    tmp, _ = world
    assert go(tmp, server, "check")[0] == 1


def test_seed_verifies_before_storing(world):
    tmp, _ = world
    (tmp / "state" / "state.json").unlink()
    server = FakeServer("the-pass")
    rc = eb.main(["seed"], env={"STATE_DIR": str(tmp / "state"), "VAULT_URL": "http://vw/vw",
                                "GRANTEE_EMAIL": GRANTEE, "GRANTOR_EMAIL": GRANTOR},
                 opener=server, log=lambda m: None, stdin=io.StringIO("wrong\n"))
    assert rc == 1 and not os.path.exists(tmp / "state" / "state.json")
    rc = eb.main(["seed"], env={"STATE_DIR": str(tmp / "state"), "VAULT_URL": "http://vw/vw",
                                "GRANTEE_EMAIL": GRANTEE, "GRANTOR_EMAIL": GRANTOR},
                 opener=server, log=lambda m: None, stdin=io.StringIO("the-pass\n"))
    assert rc == 0 and state_of(tmp)["password"] == "the-pass"


def test_generated_passwords_are_long_and_unambiguous():
    p = eb.new_password()
    assert len(p.replace("-", "")) == 25 and not set(p) & set("0O1lI")
