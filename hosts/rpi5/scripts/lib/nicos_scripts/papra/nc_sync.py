#!/usr/bin/env python3
"""Papra → Nextcloud archive reconciler.

Per pass:
  1. read Papra's SQLite (read-only): documents, tags, document_date;
  2. place each document at <ARCHIVE>/<Type>/<Year>/<name>, copied out of Papra's
     blob store — Type from the first TYPE_TAGS tag, every other tag stays a tag;
  3. prune archive files whose document is gone;
  4. `occ files:scan` the mount, only when something changed or lacks a fileid;
  5. mirror the Papra tags as Nextcloud systemtags (oc_systemtag* in PG).

The archive is derived and read-only: papra:papra 0755, outside the Nextcloud
user dir (which Tailscale Drive shares as root), seen by Nextcloud through a
read-only files_external mount. Papra's own files are never touched.

Writes nothing unless PAPRA_NC_SYNC_APPLY=1.

Env:
  PAPRA_DB  PAPRA_DOCUMENTS_ROOT  PAPRA_ARCHIVE_ROOT  PAPRA_ARCHIVE_MOUNT
  PAPRA_STATE_DIR  PAPRA_ARCHIVE_OWNER (default papra)  PAPRA_NC_SYNC_APPLY
  NC_OCC  NC_USER  NC_CONFIG  NC_PG_HOST/PORT/DB/USER
"""

import datetime
import grp
import os
import pwd
import re
import shutil
import sqlite3
import subprocess
import sys
import unicodedata
from dataclasses import dataclass, field

from ..logs import logger
from ..secrets import env_int, env_str
from ..state import load_json, save_json

# Document-type tags, most specific first: the first one a document carries is
# its folder. Everything else (Abonnement, Streaming, Impôts, …) stays a tag —
# of 455 docs only 49 carry a single tag, so topics can't be folders.
TYPE_TAGS = [
    "Facture télécom",
    "Fiche de paie",
    "Avis d'imposition",
    "Déclaration fiscale",
    "Taxe d'habitation",
    "Carte d'identité",
    "Passeport",
    "Relevé bancaire",
    "RIB",
    "Bail",
    "Contrat",
    "Attestation",
    "Facture",
    "Document administratif",
]

# No meaningful year — and mostly the documents that carry no date at all.
UNDATED_TYPES = {"Carte d'identité", "Passeport", "RIB", "Bail", "Contrat"}

UNCLASSIFIED = "Non classé"
UNDATED_YEAR = "Sans date"

_UNSAFE = re.compile(r'[/\\:*?"<>|\x00-\x1f]')
# The Paperless import id Papra appended to every migrated name: "bill__419.pdf".
_IMPORT_SUFFIX = re.compile(r"__\d+(?=\.[A-Za-z0-9]+$|$)")


@dataclass(frozen=True)
class Config:
    papra_db: str = "/var/lib/papra/db.sqlite"
    docs_root: str = "/mnt/data/papra/documents"
    archive: str = "/mnt/data/papra-archive"
    mount: str = "Papra"
    state_dir: str = "/var/lib/papra-nc-sync"
    owner: str = "papra"
    occ: str = "nextcloud-occ"
    nc_user: str = "nsimon"
    nc_config: str = "/mnt/data/nextcloud/config/config.php"
    pg: dict = field(default_factory=dict)
    apply: bool = False

    @classmethod
    def from_env(cls, env=None):
        d = cls()
        return cls(
            papra_db=env_str("PAPRA_DB", d.papra_db, env),
            docs_root=env_str("PAPRA_DOCUMENTS_ROOT", d.docs_root, env),
            archive=env_str("PAPRA_ARCHIVE_ROOT", d.archive, env),
            mount=env_str("PAPRA_ARCHIVE_MOUNT", d.mount, env),
            state_dir=env_str("PAPRA_STATE_DIR", d.state_dir, env),
            owner=env_str("PAPRA_ARCHIVE_OWNER", d.owner, env),
            occ=env_str("NC_OCC", d.occ, env),
            nc_user=env_str("NC_USER", d.nc_user, env),
            nc_config=env_str("NC_CONFIG", d.nc_config, env),
            pg={
                "host": env_str("NC_PG_HOST", "127.0.0.1", env),
                "port": env_int("NC_PG_PORT", 5432, env),
                "dbname": env_str("NC_PG_DB", "nextcloud_production", env),
                "user": env_str("NC_PG_USER", "nextcloud_user", env),
            },
            apply=env_str("PAPRA_NC_SYNC_APPLY", "", env) == "1",
        )

    @property
    def manifest(self):
        return os.path.join(self.state_dir, "manifest.json")


def safe_name(name, fallback="document"):
    name = unicodedata.normalize("NFC", name or "").strip().strip(".")
    name = _IMPORT_SUFFIX.sub("", _UNSAFE.sub("_", name))
    return name[:180] or fallback


def read_documents(papra_db):
    """-> ({doc_id: {name, key, date, tags}} for live documents, every tag name)."""
    con = sqlite3.connect(f"file:{papra_db}?mode=ro", uri=True)
    try:
        docs = {
            did: {"name": name, "key": key, "date": ddate, "tags": []}
            for did, name, key, ddate in con.execute(
                "SELECT id, original_name, original_storage_key, document_date "
                "FROM documents WHERE is_deleted = 0 AND deleted_at IS NULL")
        }
        for did, tag in con.execute(
            "SELECT dt.document_id, t.name FROM documents_tags dt "
            "JOIN tags t ON t.id = dt.tag_id ORDER BY t.name"
        ):
            if did in docs:
                docs[did]["tags"].append(tag)
        names = sorted({r[0] for r in con.execute("SELECT name FROM tags")})
        return docs, names
    finally:
        con.close()


def classify(doc):
    """(type folder, year folder or None)."""
    tags = set(doc["tags"])
    folder = next((t for t in TYPE_TAGS if t in tags), UNCLASSIFIED)
    if folder in UNDATED_TYPES:
        return folder, None
    if not doc["date"]:
        return folder, UNDATED_YEAR
    return folder, str(datetime.datetime.fromtimestamp(doc["date"] // 1000, datetime.UTC).year)


def target_rel(doc_id, doc, taken):
    """Archive path relative to the root; a clash gets the doc id's tail."""
    folder, year = classify(doc)
    parts = [safe_name(folder)] + ([year] if year else [])
    base = safe_name(doc["name"], fallback=doc_id)
    rel = os.path.join(*parts, base)
    if taken.get(rel) not in (None, doc_id):
        stem, ext = os.path.splitext(base)
        rel = os.path.join(*parts, f"{stem}-{doc_id[-6:]}{ext}")
    taken[rel] = doc_id
    return rel


class Owner:
    """chown to the archive owner; a no-op when that user doesn't exist (tests)."""

    def __init__(self, name):
        try:
            self.ids = (pwd.getpwnam(name).pw_uid, grp.getgrnam(name).gr_gid)
        except KeyError:
            self.ids = None

    def __call__(self, path):
        if self.ids:
            os.chown(path, *self.ids)


def makedirs(root, rel_dir, chown):
    path = root
    for part in rel_dir.split(os.sep) if rel_dir else []:
        path = os.path.join(path, part)
        if not os.path.isdir(path):
            os.mkdir(path, 0o755)
            chown(path)


def place(cfg, docs, manifest, chown, log):
    """-> ({doc_id: relpath}, copied, moved). Only writes when cfg.apply."""
    # Existing placements claim their slot first, so only a newcomer gets suffixed.
    taken = {rel: did for did, rel in manifest.items() if did in docs}
    placed, copied, moved = {}, 0, 0
    for did, doc in sorted(docs.items()):
        rel = target_rel(did, doc, taken)
        dest = os.path.join(cfg.archive, rel)
        prev = manifest.get(did)
        prev_abs = os.path.join(cfg.archive, prev) if prev else None
        if prev == rel and os.path.exists(dest):
            placed[did] = rel
            continue
        if prev_abs and prev != rel and os.path.exists(prev_abs):
            # Re-tagged, or a date finally resolved.
            if cfg.apply:
                makedirs(cfg.archive, os.path.dirname(rel), chown)
                os.replace(prev_abs, dest)
            moved += 1
        else:
            src = os.path.join(cfg.docs_root, doc["key"] or "")
            if not doc["key"] or not os.path.isfile(src):
                log(f"[{did}] blob missing ({doc['key']!r}) — skip")
                continue
            if cfg.apply:
                makedirs(cfg.archive, os.path.dirname(rel), chown)
                tmp = dest + ".part"
                shutil.copy2(src, tmp)
                os.chmod(tmp, 0o644)
                chown(tmp)
                os.replace(tmp, dest)
            copied += 1
        placed[did] = rel
    return placed, copied, moved


def prune(cfg, placed):
    """Remove archive files not backed by a live document, then empty dirs."""
    keep = {os.path.join(cfg.archive, rel) for rel in placed.values()}
    removed = 0
    for root, _dirs, files in os.walk(cfg.archive):
        for f in files:
            p = os.path.join(root, f)
            if p not in keep:
                if cfg.apply:
                    os.unlink(p)
                removed += 1
    if cfg.apply:
        for root, dirs, files in os.walk(cfg.archive, topdown=False):
            if root != cfg.archive and not os.listdir(root):
                os.rmdir(root)
    return removed


def nc_pg_password(nc_config):
    # nextcloud-pg-password is postgres-owned; Nextcloud's config.php has it too.
    with open(nc_config) as fh:
        m = re.search(r"'dbpassword'\s*=>\s*'([^']*)'", fh.read())
    if not m:
        raise RuntimeError("dbpassword not found in " + nc_config)
    return m.group(1)


def connect_pg(cfg):
    # Lazy, so the module (and its tests) load without psycopg2.
    import psycopg2

    return psycopg2.connect(password=nc_pg_password(cfg.nc_config), **cfg.pg)


def occ_scan(cfg, run):
    run([cfg.occ, "files:scan", "--path", f"/{cfg.nc_user}/files/{cfg.mount}", "--quiet"])


def archive_fileids(cur, cfg):
    """{relpath: fileid} for the archive's storage, or None if it isn't mounted.

    A local:: storage's oc_filecache paths are relative to the mount root.
    """
    cur.execute("SELECT numeric_id FROM oc_storages WHERE id = %s",
                (f"local::{cfg.archive.rstrip('/')}/",))
    row = cur.fetchone()
    if not row:
        return None
    cur.execute("SELECT path, fileid FROM oc_filecache WHERE storage = %s", (row[0],))
    return dict(cur.fetchall())


def sync_tags(cfg, cur, docs, papra_tags, placed, fileids):
    """-> (files tagged, mappings added, mappings removed).

    Only tags Papra knows are ever removed, so a tag added by hand in Nextcloud
    survives.
    """
    names = sorted({t for d in docs.values() for t in d["tags"]})
    cur.execute("SELECT name, id FROM oc_systemtag WHERE visibility = 1 AND name = ANY(%s)",
                (papra_tags,))
    owned = {i for _n, i in cur.fetchall()}
    cur.execute("SELECT name, id FROM oc_systemtag WHERE visibility = 1 AND name = ANY(%s)",
                (names,))
    tagids = dict(cur.fetchall())
    for name in names:
        if name not in tagids and cfg.apply:
            cur.execute("INSERT INTO oc_systemtag(name, visibility, editable) "
                        "VALUES(%s, 1, 1) RETURNING id", (name,))
            tagids[name] = cur.fetchone()[0]
    owned |= set(tagids.values())

    tagged = added = removed = 0
    for did, rel in sorted(placed.items()):
        fid = fileids.get(rel)
        if fid is None:
            continue
        want = {tagids[t] for t in docs[did]["tags"] if t in tagids}
        cur.execute("SELECT systemtagid FROM oc_systemtag_object_mapping "
                    "WHERE objecttype = 'files' AND objectid = %s", (str(fid),))
        have = {r[0] for r in cur.fetchall()}
        for tid in sorted(want - have):
            if cfg.apply:
                cur.execute("INSERT INTO oc_systemtag_object_mapping"
                            "(objectid, objecttype, systemtagid) VALUES(%s, 'files', %s)",
                            (str(fid), tid))
            added += 1
        for tid in sorted((have & owned) - want):
            if cfg.apply:
                cur.execute("DELETE FROM oc_systemtag_object_mapping WHERE objecttype = 'files' "
                            "AND objectid = %s AND systemtagid = %s", (str(fid), tid))
            removed += 1
        tagged += 1
    # A move outside Nextcloud is a delete + create to its scanner, so the old
    # fileid's mappings are left pointing at nothing.
    if cfg.apply and owned:
        cur.execute("DELETE FROM oc_systemtag_object_mapping m WHERE objecttype = 'files' "
                    "AND systemtagid = ANY(%s) AND NOT EXISTS "
                    "(SELECT 1 FROM oc_filecache f WHERE f.fileid::text = m.objectid)",
                    (sorted(owned),))
        removed += max(cur.rowcount, 0)
    return tagged, added, removed


def reconcile(cfg, connect=None, run=None, log=None):
    log = log or logger("papra-nc-sync")
    run = run or (lambda argv: subprocess.run(argv, check=True, stdout=subprocess.DEVNULL))
    connect = connect or connect_pg

    docs, papra_tags = read_documents(cfg.papra_db)
    if not docs:
        log("no documents in Papra — nothing to do")
        return 0
    manifest = load_json(cfg.manifest, {})
    chown = Owner(cfg.owner)
    if cfg.apply:
        os.makedirs(cfg.state_dir, exist_ok=True)

    placed, copied, moved = place(cfg, docs, manifest, chown, log)
    removed = prune(cfg, placed) if os.path.isdir(cfg.archive) else 0
    if cfg.apply:
        save_json(cfg.manifest, placed, indent=1, sort_keys=True)

    conn = connect(cfg)
    conn.autocommit = True
    try:
        cur = conn.cursor()
        fileids = archive_fileids(cur, cfg)
        if fileids is None:
            log(f"no Nextcloud storage for local::{cfg.archive}/ — is papra-nc-archive-mount up?")
            return 1
        changed = copied or moved or removed
        if cfg.apply and (changed or any(rel not in fileids for rel in placed.values())):
            occ_scan(cfg, run)
            fileids = archive_fileids(cur, cfg)
        tagged, added, dropped = sync_tags(cfg, cur, docs, papra_tags, placed, fileids)
    finally:
        conn.close()

    log(f"DONE {'' if cfg.apply else '(dry-run) '}{len(placed)} filed "
        f"(+{copied} copied, {moved} moved, {removed} pruned); {tagged} files tagged "
        f"(+{added}/-{dropped} tags), {len(placed) - tagged} awaiting scan")
    return 0


def main(env=None, connect=None, run=None, log=None):
    return reconcile(Config.from_env(env), connect=connect, run=run, log=log)


if __name__ == "__main__":
    sys.exit(main())
