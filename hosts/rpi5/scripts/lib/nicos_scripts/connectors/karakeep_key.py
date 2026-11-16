"""karakeep-mcp-key: mint the API key Aperture's karakeep connector uses.

Karakeep makes API keys only through its UI, so this writes one the way
packages/trpc/auth.ts does (v2: `ak2_<keyId>_<secret>`, sha256 of the secret,
base64) into its SQLite, for the oldest admin, and keeps the plain key in
KEY_FILE (0600). Runs as the karakeep user before each karakeep-mcp start; a
key Karakeep still accepts is left alone.
Env: KARAKEEP_DB (/var/lib/karakeep/db.db), KEY_FILE.
"""

import base64
import hashlib
import os
import secrets
import sqlite3
import sys
from dataclasses import dataclass
from pathlib import Path

from ..logs import logger
from ..secrets import env_str

log = logger("karakeep-mcp-key", lambda: sys.stderr)
NAME = "aperture-mcp"


@dataclass(frozen=True)
class Config:
    db: str
    key_file: str

    @classmethod
    def from_env(cls, env=None):
        return cls(
            db=env_str("KARAKEEP_DB", "/var/lib/karakeep/db.db", env),
            key_file=env_str("KEY_FILE", "", env),
        )


def digest_of(secret):
    return base64.b64encode(hashlib.sha256(secret.encode()).digest()).decode()


def new_key(token_hex=secrets.token_hex):
    key_id, secret = token_hex(10), token_hex(16)
    return key_id, f"ak2_{key_id}_{secret}", digest_of(secret)


def still_valid(con, plain):
    """What Karakeep's v2 check accepts: prefix, keyId, sha256 of the secret."""
    parts = plain.split("_")
    if len(parts) != 3 or parts[0] != "ak2":
        return False
    row = con.execute(
        "select keyHash from apiKey where keyId = ?", (parts[1],)
    ).fetchone()
    return row is not None and row[0] == digest_of(parts[2])


def ensure(con, key_file, token_hex=secrets.token_hex):
    """'kept', 'minted', or 'no admin'."""
    path = Path(key_file)
    if path.is_file() and still_valid(con, path.read_text().strip()):
        return "kept"
    row = con.execute(
        "select id from user where role = 'admin' order by rowid limit 1"
    ).fetchone()
    if row is None:
        return "no admin"
    key_id, plain, digest = new_key(token_hex)
    with con:
        con.execute("delete from apiKey where name = ? and userId = ?", (NAME, row[0]))
        con.execute(
            "insert into apiKey (id, name, createdAt, keyId, keyHash, scopes, userId)"
            " values (?, ?, unixepoch(), ?, ?, '[\"fullaccess\"]', ?)",
            (token_hex(12), NAME, key_id, digest, row[0]),
        )
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(plain + "\n")
    return "minted"


def main(argv=None, env=None):
    del argv
    cfg = Config.from_env(env)
    if not cfg.key_file:
        log("FATAL: KEY_FILE unset")
        return 2
    con = sqlite3.connect(cfg.db, timeout=30)
    try:
        result = ensure(con, cfg.key_file)
    finally:
        con.close()
    log(result)
    return 1 if result == "no admin" else 0


if __name__ == "__main__":
    sys.exit(main())
