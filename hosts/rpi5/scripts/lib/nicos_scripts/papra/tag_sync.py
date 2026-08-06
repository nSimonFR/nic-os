#!/usr/bin/env python3
"""Papra → Nextcloud tag sync (webhook receiver).

Papra fires an HMAC-signed webhook on document.tags.changed. This tiny receiver
verifies the signature, pulls the document's CURRENT tags straight from Papra's
SQLite (source of truth — the payload only needs to tell us WHICH doc), finds the
matching file in Nextcloud by its original filename, and mirrors the tags as
Nextcloud systemtags (writing oc_systemtag + oc_systemtag_object_mapping in
Postgres directly, as nextcloud_user).

Docs with no Nextcloud counterpart (e.g. Proton-sourced) are skipped — Papra
stays the searchable archive for those.

Env:
  LISTEN_ADDR (default 127.0.0.1)  LISTEN_PORT (default 8347)
  PAPRA_DB (default /var/lib/papra/db.sqlite)
  PAPRA_WEBHOOK_SECRET_FILE (HMAC secret)
  NC_PG_HOST/PORT/DB/USER  NC_CONFIG  NC_USER (Nextcloud username)
"""

import base64
import hashlib
import hmac
import re
import sqlite3
import sys
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from ..secrets import env_int, env_str, read_secret

DEFAULT_PAPRA_DB = "/var/lib/papra/db.sqlite"
DEFAULT_NC_CONFIG = "/mnt/data/nextcloud/config/config.php"
DOC_RE = re.compile(rb"doc_[A-Za-z0-9]{16,}")


@dataclass(frozen=True)
class Config:
    secret: bytes = b""
    papra_db: str = DEFAULT_PAPRA_DB
    nc_user: str = "nsimon"
    nc_config: str = DEFAULT_NC_CONFIG
    listen_addr: str = "127.0.0.1"
    listen_port: int = 8347
    pg: dict = field(default_factory=dict)

    @classmethod
    def from_env(cls, env=None):
        # The secret was read at MODULE level before (`open(os.environ[...])`), so
        # importing this file anywhere without the agenix mount raised KeyError.
        secret_file = env_str("PAPRA_WEBHOOK_SECRET_FILE", "", env)
        return cls(
            secret=read_secret(secret_file).encode() if secret_file else b"",
            papra_db=env_str("PAPRA_DB", DEFAULT_PAPRA_DB, env),
            nc_user=env_str("NC_USER", "nsimon", env),
            nc_config=env_str("NC_CONFIG", DEFAULT_NC_CONFIG, env),
            listen_addr=env_str("LISTEN_ADDR", "127.0.0.1", env),
            listen_port=env_int("LISTEN_PORT", 8347, env),
            pg={
                "host": env_str("NC_PG_HOST", "127.0.0.1", env),
                "port": env_int("NC_PG_PORT", 5432, env),
                "dbname": env_str("NC_PG_DB", "nextcloud_production", env),
                "user": env_str("NC_PG_USER", "nextcloud_user", env),
            },
        )


def nc_pg_password(nc_config):
    # nextcloud-pg-password is postgres-owned; instead read the password from
    # Nextcloud's own config.php (readable by the nextcloud user we run as).
    with open(nc_config) as fh:
        m = re.search(r"'dbpassword'\s*=>\s*'([^']*)'", fh.read())
    if not m:
        raise RuntimeError("dbpassword not found in " + nc_config)
    return m.group(1)


def connect_pg(cfg):
    # Imported lazily so the module stays importable (and testable) without
    # psycopg2 present — every DB test injects a fake connection instead.
    import psycopg2

    return psycopg2.connect(password=nc_pg_password(cfg.nc_config), **cfg.pg)


def verify_signature(secret, wid, wts, wsig, body):
    """Standard Webhooks (svix) scheme, as used by Papra:
      signed content = "{webhook-id}.{webhook-timestamp}.{body}"
      webhook-signature: space-separated "v1,<base64(hmac_sha256)>" entries

    -> (ok, expected). `expected` is returned for the rejection log line.
    """
    # svix secrets may be "whsec_<base64>"; ours is a plain string -> raw bytes
    key = secret
    if key.startswith(b"whsec_"):
        key = base64.b64decode(key[6:])
    signed = wid.encode() + b"." + wts.encode() + b"." + body
    expected = base64.b64encode(hmac.new(key, signed, hashlib.sha256).digest()).decode()
    sigs = [p.split(",", 1)[1] for p in wsig.split() if p.startswith("v1,")]
    return any(hmac.compare_digest(expected, s) for s in sigs), expected, sigs


def doc_ids(body):
    """Every distinct Papra doc id in the payload, in order of appearance."""
    ids = []
    for m in DOC_RE.findall(body):
        d = m.decode()
        if d not in ids:
            ids.append(d)
    return ids


def papra_doc(papra_db, doc_id):
    con = sqlite3.connect(f"file:{papra_db}?mode=ro", uri=True)
    try:
        row = con.execute(
            "SELECT original_name FROM documents WHERE id=? AND deleted_at IS NULL", (doc_id,)
        ).fetchone()
        if not row:
            return None, []
        tags = [r[0] for r in con.execute(
            "SELECT t.name FROM documents_tags dt JOIN tags t ON t.id=dt.tag_id WHERE dt.document_id=?",
            (doc_id,))]
        return row[0], tags
    finally:
        con.close()


def candidate_names(name):
    """Candidate filenames: exact, then with Papra's import suffix "__N" stripped
    (Paperless originals were re-imported as "<title>__<N>.pdf")."""
    stripped = re.sub(r"__\d+(\.[A-Za-z0-9]+)$", r"\1", name)
    return [name] if stripped == name else [name, stripped]


def find_file(cur, nc_user, names):
    for cand in names:
        cur.execute(
            "SELECT fc.fileid, fc.path FROM oc_filecache fc "
            "JOIN oc_storages s ON s.numeric_id = fc.storage "
            "WHERE fc.name = %s AND s.id = %s ORDER BY fc.fileid DESC LIMIT 1",
            (cand, f"home::{nc_user}"))
        r = cur.fetchone()
        if r:
            return r
    return None


def apply_systemtags(cur, fileid, tags):
    """Create each tag if absent, then map it to the file unless already mapped."""
    applied = []
    for tag in tags:
        cur.execute("SELECT id FROM oc_systemtag WHERE name=%s AND visibility=1 LIMIT 1", (tag,))
        tr = cur.fetchone()
        if tr:
            tagid = tr[0]
        else:
            cur.execute(
                "INSERT INTO oc_systemtag(name,visibility,editable) VALUES(%s,1,1) RETURNING id", (tag,))
            tagid = cur.fetchone()[0]
        cur.execute(
            "SELECT 1 FROM oc_systemtag_object_mapping WHERE objecttype='files' AND objectid=%s AND systemtagid=%s",
            (str(fileid), tagid))
        if not cur.fetchone():
            cur.execute(
                "INSERT INTO oc_systemtag_object_mapping(objectid,objecttype,systemtagid) VALUES(%s,'files',%s)",
                (str(fileid), tagid))
        applied.append(tag)
    return applied


def sync(cfg, doc_id, connect=None):
    name, tags = papra_doc(cfg.papra_db, doc_id)
    if not name:
        return f"[{doc_id}] unknown/deleted doc — skip"
    if not tags:
        return f"[{doc_id}] no tags yet — skip"

    conn = (connect or connect_pg)(cfg)
    conn.autocommit = True
    cur = conn.cursor()
    try:
        r = find_file(cur, cfg.nc_user, candidate_names(name))
        if not r:
            return f"[{doc_id}] no Nextcloud file for {name!r} — skip"
        fileid, path = r
        applied = apply_systemtags(cur, fileid, tags)
        return f"[{doc_id}] tagged {path} (fileid {fileid}) -> {applied}"
    finally:
        conn.close()


def make_handler(cfg, sync_fn=None, log=print):
    do_sync = sync_fn or (lambda doc_id: sync(cfg, doc_id))

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _reply(self, code, msg):
            self.send_response(code)
            self.end_headers()
            self.wfile.write(msg.encode())

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(n)
            ok, expected, sigs = verify_signature(
                cfg.secret,
                self.headers.get("webhook-id", ""),
                self.headers.get("webhook-timestamp", ""),
                self.headers.get("webhook-signature", ""),
                body,
            )
            if not ok:
                log(f"REJECT bad signature id={self.headers.get('webhook-id', '')} "
                    f"sigs={sigs} expected={expected[:16]}")
                return self._reply(401, "bad signature")
            ids = doc_ids(body)
            if not ids:
                log(f"no doc id in payload: {body[:200]!r}")
                return self._reply(200, "no doc id")
            out = []
            for d in ids:
                try:
                    res = do_sync(d)
                except Exception as e:  # noqa: BLE001 - one bad doc must not 500 the hook
                    res = f"[{d}] ERROR {e}"
                log(res)
                out.append(res)
            self._reply(200, "; ".join(out))

        def do_GET(self):
            self._reply(200, "papra-webhook-tagsync ok")

    return H


def serve(cfg, server_class=ThreadingHTTPServer):
    print(f"listening {cfg.listen_addr}:{cfg.listen_port}", flush=True)
    server_class((cfg.listen_addr, cfg.listen_port), make_handler(cfg)).serve_forever()


def main(env=None):
    cfg = Config.from_env(env)
    if not cfg.secret:
        print("FATAL: PAPRA_WEBHOOK_SECRET_FILE is not set — refusing to accept "
              "unsigned webhooks", file=sys.stderr)
        return 1
    serve(cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
