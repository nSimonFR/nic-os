"""vault-agent must write items the owner's client can decrypt with the org key,
never overwrite without --update, never print a secret it did not generate, and
hand the org key to the configured owner only.
"""

import base64
import io
import json
import urllib.error
import urllib.parse

import pytest

from conftest import FakeResponse
from nicos_scripts.vaultwarden import agents as va
from nicos_scripts.vaultwarden import bwcrypto

BOT = "bot@example.com"
OWNER = "owner@example.com"
PASSWORD = "bot-pass"
KDF = {"type": bwcrypto.PBKDF2, "iterations": 1000, "memory": None, "parallelism": None}
USER_KEY = bytes(range(64))
ORG_KEY = bytes(range(64, 128))


@pytest.fixture(scope="module")
def keys():
    """(public b64, private wrapped by USER_KEY, private DER) for the bot and the owner."""
    from cryptography.hazmat.primitives import serialization as ser
    from cryptography.hazmat.primitives.asymmetric import rsa

    pairs = {}
    for who in ("bot", "owner"):
        priv = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        der = priv.private_bytes(ser.Encoding.DER, ser.PrivateFormat.PKCS8, ser.NoEncryption())
        pub = priv.public_key().public_bytes(ser.Encoding.DER, ser.PublicFormat.SubjectPublicKeyInfo)
        pairs[who] = (base64.b64encode(pub).decode(), enc_bytes(der, USER_KEY), der)
    return pairs


def enc_bytes(data, key):
    return bwcrypto.encrypt(data, *bwcrypto.split(key))


def enc(text, key=ORG_KEY):
    return bwcrypto.encrypt(text.encode(), *bwcrypto.split(key))


def dec(s, key=ORG_KEY):
    return bwcrypto.decrypt(s, *bwcrypto.split(key)).decode() if s else None


class FakeVault:
    """urlopen-compatible: login, sync, ciphers, members and confirm."""

    def __init__(self, keys, org=True, members=None):
        mkey = bwcrypto.master_key(PASSWORD, BOT, KDF)
        self.hash = bwcrypto.password_hash(mkey, PASSWORD)
        self.akey = bwcrypto.encrypt(USER_KEY, *bwcrypto.stretch(mkey))
        self.keys = keys
        self.orgs = []
        self.collections = []
        self.ciphers = []
        self.members = members if members is not None else []
        self.calls = []
        if org:
            self.add_org(bwcrypto.rsa_encrypt(ORG_KEY, keys["bot"][0]), enc("Agents"))

    def add_org(self, key, collection_name):
        self.orgs.append({"id": "org1", "name": "Agents", "key": key})
        self.collections.append({"id": "col1", "organizationId": "org1", "name": collection_name})

    def __call__(self, req, timeout=None):
        url = urllib.parse.urlparse(req.full_url)
        path, method = url.path.removeprefix("/vw"), req.get_method()
        self.calls.append((method, path))
        body = json.loads(req.data) if req.data and path != "/identity/connect/token" else None
        if path == "/identity/accounts/prelogin":
            return self.reply({"kdf": 0, "kdfIterations": KDF["iterations"]})
        if path == "/identity/connect/token":
            form = dict(urllib.parse.parse_qsl(req.data.decode()))
            if form["password"] != self.hash or form["device_identifier"] != va.DEVICE_ID:
                raise self.error(req, 400)
            return self.reply({"access_token": "tok", "Key": self.akey, "PrivateKey": self.keys["bot"][1]})
        if req.get_header("Authorization") != "Bearer tok":
            raise self.error(req, 401)
        if path == "/api/sync":
            return self.reply({"profile": {"id": "bot-id", "organizations": self.orgs},
                               "collections": self.collections, "ciphers": self.ciphers})
        if path == "/api/ciphers/create":
            assert body["cipher"]["encryptedFor"] == "bot-id"
            c = dict(body["cipher"], id=f"c{len(self.ciphers) + 1}",
                     collectionIds=body["collectionIds"], revisionDate="r1")
            self.ciphers.append(c)
            return self.reply(c)
        if method == "PUT" and path.startswith("/api/ciphers/"):
            cid = path.rsplit("/", 1)[1]
            i = next(i for i, c in enumerate(self.ciphers) if c["id"] == cid)
            assert body["lastKnownRevisionDate"] == self.ciphers[i]["revisionDate"]
            self.ciphers[i] = dict(body, id=cid, collectionIds=self.ciphers[i]["collectionIds"], revisionDate="r2")
            return self.reply(self.ciphers[i])
        if path == "/api/users/owner-id/public-key":
            return self.reply({"publicKey": self.keys["owner"][0]})
        if path == "/api/organizations/org1/users" and method == "GET":
            return self.reply({"data": self.members})
        if path.startswith("/api/organizations/org1/users/") and path.endswith("/confirm"):
            self.confirmed = (path.split("/")[-2], body["key"])
            return self.reply({})
        raise self.error(req, 404)

    @staticmethod
    def reply(obj):
        return FakeResponse(json.dumps(obj).encode())

    @staticmethod
    def error(req, code):
        return urllib.error.HTTPError(req.full_url, code, "x", {}, io.BytesIO(b""))

    def writes(self):
        return [c for c in self.calls if c[0] in ("POST", "PUT") and not c[1].startswith("/identity")]


@pytest.fixture
def run(tmp_path, logged):
    (tmp_path / "pw").write_text(PASSWORD + "\n")
    lines, log = logged

    def go(server, *argv, stdin="", dry_run=False):
        out = []
        env = {"VAULT_URL": "http://vw/vw", "VAULT_AGENT_EMAIL": BOT, "VAULT_OWNER_EMAIL": OWNER,
               "VAULT_AGENT_PASSWORD_FILE": str(tmp_path / "pw"), "DRY_RUN": "1" if dry_run else "0"}
        rc = va.main(list(argv), env=env, opener=server, log=log, stdin=io.StringIO(stdin), out=out.append)
        return rc, out, lines

    return go


def test_add_writes_a_login_the_org_key_opens(keys, run):
    server = FakeVault(keys)
    rc, out, _ = run(server, "add", "--name", "Agent Vault", "--username", "admin@x",
                     "--uri", "https://av.example", "--password-file", "-", stdin="s3cret\n")
    assert rc == 0
    assert json.loads(out[0]) == {"action": "created", "id": "c1", "name": "Agent Vault"}
    c = server.ciphers[0]
    assert c["organizationId"] == "org1" and c["collectionIds"] == ["col1"]
    assert dec(c["name"]) == "Agent Vault"
    assert dec(c["login"]["username"]) == "admin@x"
    assert dec(c["login"]["password"]) == "s3cret"
    assert dec(c["login"]["uris"][0]["uri"]) == "https://av.example"


def test_existing_name_is_refused_without_update(keys, run):
    server = FakeVault(keys)
    run(server, "add", "--name", "A", "--password-file", "-", stdin="one")
    rc, out, lines = run(server, "add", "--name", "A", "--password-file", "-", stdin="two")
    assert rc == 3 and out == []
    assert len(server.ciphers) == 1 and dec(server.ciphers[0]["login"]["password"]) == "one"
    assert "--update" in lines[-1]


def test_update_keeps_the_old_password_in_history(keys, run):
    server = FakeVault(keys)
    run(server, "add", "--name", "A", "--password-file", "-", stdin="one")
    rc, out, _ = run(server, "add", "--name", "A", "--password-file", "-", "--update", stdin="two")
    assert rc == 0 and json.loads(out[0])["action"] == "updated"
    c = server.ciphers[0]
    assert dec(c["login"]["password"]) == "two"
    assert [dec(h["password"]) for h in c["passwordHistory"]] == ["one"]


def test_generate_prints_the_password_it_stored(keys, run):
    server = FakeVault(keys)
    rc, out, _ = run(server, "add", "--name", "New", "--generate", "30")
    printed = json.loads(out[0])["password"]
    assert rc == 0 and len(printed) == 30
    assert dec(server.ciphers[0]["login"]["password"]) == printed


def test_list_never_prints_a_password(keys, run):
    server = FakeVault(keys)
    run(server, "add", "--name", "A", "--username", "u", "--password-file", "-", stdin="hunter2")
    rc, out, _ = run(server, "list")
    assert rc == 0 and "hunter2" not in out[0]
    assert json.loads(out[0]) == [{"id": "c1", "name": "A", "username": "u", "uris": []}]



def test_dry_run_writes_nothing(keys, run):
    server = FakeVault(keys)
    rc, out, _ = run(server, "add", "--name", "A", "--generate", dry_run=True)
    assert rc == 0 and server.writes() == []



def test_bot_outside_the_org_fails(keys, run):
    rc, _, lines = run(FakeVault(keys, org=False), "add", "--name", "A", "--generate")
    assert rc == 1 and "not in org" in lines[-1]



def test_confirm_hands_the_org_key_to_the_owner_only(keys, run):
    members = [
        {"id": "m-other", "userId": "other-id", "email": "intruder@example.com", "status": va.MEMBER_ACCEPTED},
        {"id": "m-owner", "userId": "owner-id", "email": OWNER, "status": va.MEMBER_ACCEPTED},
    ]
    server = FakeVault(keys, members=members)
    rc, _, _ = run(server, "confirm")
    assert rc == 0
    member, key = server.confirmed
    assert member == "m-owner"
    assert bwcrypto.rsa_decrypt(key, keys["owner"][2]) == ORG_KEY


def test_confirm_waits_for_the_owner_to_accept(keys, run):
    server = FakeVault(keys, members=[{"id": "m", "userId": "owner-id", "email": OWNER, "status": 0}])
    rc, _, _ = run(server, "confirm")
    assert rc == 1 and not hasattr(server, "confirmed")
