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
  NC_PG_HOST/PORT/DB/USER  NC_PG_PASSWORD_FILE  NC_USER (Nextcloud username)
"""
import base64
import hashlib
import hmac
import os
import re
import sqlite3
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg2

PAPRA_DB = os.environ.get("PAPRA_DB", "/var/lib/papra/db.sqlite")
SECRET = open(os.environ["PAPRA_WEBHOOK_SECRET_FILE"], "rb").read().strip()
NC_USER = os.environ.get("NC_USER", "nsimon")
LISTEN_ADDR = os.environ.get("LISTEN_ADDR", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8347"))
DOC_RE = re.compile(rb"doc_[A-Za-z0-9]{16,}")


def nc_pg_password():
    # nextcloud-pg-password is postgres-owned; instead read the password from
    # Nextcloud's own config.php (readable by the nextcloud user we run as).
    cfg = os.environ.get("NC_CONFIG", "/mnt/data/nextcloud/config/config.php")
    m = re.search(r"'dbpassword'\s*=>\s*'([^']*)'", open(cfg).read())
    if not m:
        raise RuntimeError("dbpassword not found in " + cfg)
    return m.group(1)


def pg():
    return psycopg2.connect(
        host=os.environ.get("NC_PG_HOST", "127.0.0.1"),
        port=int(os.environ.get("NC_PG_PORT", "5432")),
        dbname=os.environ.get("NC_PG_DB", "nextcloud_production"),
        user=os.environ.get("NC_PG_USER", "nextcloud_user"),
        password=nc_pg_password(),
    )


def papra_doc(doc_id):
    con = sqlite3.connect(f"file:{PAPRA_DB}?mode=ro", uri=True)
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


def sync(doc_id):
    name, tags = papra_doc(doc_id)
    if not name:
        return f"[{doc_id}] unknown/deleted doc — skip"
    if not tags:
        return f"[{doc_id}] no tags yet — skip"
    # Candidate filenames: exact, then with Papra's import suffix "__N" stripped
    # (Paperless originals were re-imported as "<title>__<N>.pdf").
    candidates = [name]
    stripped = re.sub(r"__\d+(\.[A-Za-z0-9]+)$", r"\1", name)
    if stripped != name:
        candidates.append(stripped)

    conn = pg()
    conn.autocommit = True
    cur = conn.cursor()
    try:
        r = None
        for cand in candidates:
            cur.execute(
                "SELECT fc.fileid, fc.path FROM oc_filecache fc "
                "JOIN oc_storages s ON s.numeric_id = fc.storage "
                "WHERE fc.name = %s AND s.id = %s ORDER BY fc.fileid DESC LIMIT 1",
                (cand, f"home::{NC_USER}"))
            r = cur.fetchone()
            if r:
                break
        if not r:
            return f"[{doc_id}] no Nextcloud file for {name!r} — skip"
        fileid, path = r
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
        return f"[{doc_id}] tagged {path} (fileid {fileid}) -> {applied}"
    finally:
        conn.close()


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
        sig_raw = (self.headers.get("X-Signature") or self.headers.get("x-signature") or "").strip()
        got = sig_raw[7:] if sig_raw.lower().startswith("sha256=") else sig_raw
        mac = hmac.new(SECRET, body, hashlib.sha256)
        hexd = mac.hexdigest()
        b64 = base64.b64encode(mac.digest()).decode()
        ok = got and (
            hmac.compare_digest(got, hexd)
            or hmac.compare_digest(got, b64)
            or hmac.compare_digest(got.rstrip("="), b64.rstrip("="))
        )
        if not ok:
            print(f"REJECT bad/missing signature got={sig_raw[:24]!r} hex={hexd[:12]} b64={b64[:12]}", flush=True)
            return self._reply(401, "bad signature")
        ids = []
        for m in DOC_RE.findall(body):
            d = m.decode()
            if d not in ids:
                ids.append(d)
        if not ids:
            print(f"no doc id in payload: {body[:200]!r}", flush=True)
            return self._reply(200, "no doc id")
        out = []
        for d in ids:
            try:
                res = sync(d)
            except Exception as e:
                res = f"[{d}] ERROR {e}"
            print(res, flush=True)
            out.append(res)
        self._reply(200, "; ".join(out))

    def do_GET(self):
        self._reply(200, "papra-webhook-tagsync ok")


if __name__ == "__main__":
    print(f"listening {LISTEN_ADDR}:{LISTEN_PORT}", flush=True)
    ThreadingHTTPServer((LISTEN_ADDR, LISTEN_PORT), H).serve_forever()
