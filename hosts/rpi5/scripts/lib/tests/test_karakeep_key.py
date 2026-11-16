"""karakeep-mcp-key: the key it mints is the one Karakeep's v2 check accepts."""

import base64
import hashlib
import sqlite3

from nicos_scripts.connectors import karakeep_key


def _db():
    con = sqlite3.connect(":memory:")
    con.executescript(
        """
        create table user (id text primary key, role text);
        create table apiKey (id text primary key, name text not null, createdAt integer,
          lastUsedAt integer, keyId text not null unique, keyHash text not null,
          scopes text not null, userId text not null, unique(name, userId));
        insert into user values ('u-user', 'user'), ('u-admin', 'admin');
        """
    )
    return con


def _accepted(con, plain):
    _, key_id, secret = plain.split("_")
    (stored,) = con.execute(
        "select keyHash from apiKey where keyId = ?", (key_id,)
    ).fetchone()
    return base64.b64decode(stored) == hashlib.sha256(secret.encode()).digest()


def test_mints_a_v2_key_for_the_admin(tmp_path):
    con, f = _db(), tmp_path / "key"
    assert karakeep_key.ensure(con, f) == "minted"
    plain = f.read_text().strip()
    assert plain.startswith("ak2_") and _accepted(con, plain)
    assert con.execute("select userId, scopes from apiKey").fetchall() == [
        ("u-admin", '["fullaccess"]')
    ]
    assert f.stat().st_mode & 0o777 == 0o600


def test_keeps_a_valid_key_and_replaces_a_revoked_one(tmp_path):
    con, f = _db(), tmp_path / "key"
    karakeep_key.ensure(con, f)
    first = f.read_text()
    assert karakeep_key.ensure(con, f) == "kept" and f.read_text() == first
    con.execute("delete from apiKey")
    assert karakeep_key.ensure(con, f) == "minted"
    assert f.read_text() != first and _accepted(con, f.read_text().strip())
    assert con.execute("select count(*) from apiKey").fetchone() == (1,)


def test_no_admin_writes_nothing(tmp_path):
    con, f = _db(), tmp_path / "key"
    con.execute("update user set role = 'user'")
    assert karakeep_key.ensure(con, f) == "no admin"
    assert not f.exists()
