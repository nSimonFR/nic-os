#!/usr/bin/env python3
"""Papra → Nextcloud archive reconciler.

Replaces the old webhook receiver (papra-webhook-tagsync.py), which never once
succeeded: it waited on `document:tag:added`, but papra-tag-sweep.py writes
`documents_tags` straight into SQLite and bypasses Papra's API, so that event
never fires for our pipeline. Every delivery we ever got was `document:created`
firing BEFORE tagging → "no tags yet — skip". A reconciler has no such ordering
problem, self-heals, and backfills the whole archive on first run.

What it does, per pass:
  1. Read Papra's SQLite (read-only) — documents, tags, document_date.
  2. Place each document at  <ARCHIVE>/<Type>/<Year>/<name>, copying the blob
     out of Papra's storage. Type comes from the document-type tag (see
     TYPE_TAGS); everything else stays a tag, never a folder.
  3. Prune archive files whose document is gone from Papra.
  4. `occ files:scan` the external mount so Nextcloud has fileids.
  5. Mirror ALL of the document's Papra tags onto that file as Nextcloud
     systemtags (oc_systemtag + oc_systemtag_object_mapping, written directly
     as nextcloud_user — same approach the webhook receiver used).

The archive is a DERIVED, read-only mirror: /mnt/data/papra-archive is owned
papra:papra 0755 and lives OUTSIDE /mnt/data/nextcloud/data/nsimon/files, so it
is not exposed by the Tailscale Drive bind-mount and php-fpm (uid nextcloud,
not in group papra) cannot write to it. Nextcloud sees it via a read-only
files_external Local mount. Source files are never moved or deleted — the
originals in your Nextcloud tree stay exactly where they are.

Because we place the file ourselves we always know its path, so this drops the
old receiver's fragile "match by original filename, then retry with the __N
suffix stripped" heuristic entirely.

Env:
  PAPRA_DB (default /var/lib/papra/db.sqlite)
  PAPRA_DOCUMENTS_ROOT (default /mnt/data/papra/documents)
  PAPRA_ARCHIVE_ROOT   (default /mnt/data/papra-archive)
  PAPRA_ARCHIVE_MOUNT  Nextcloud mount point name (default Papra)
  PAPRA_STATE_DIR      manifest location (default /var/lib/papra-nc-sync)
  NC_OCC               path to the nextcloud-occ wrapper
  NC_PG_HOST/PORT/DB/USER  NC_CONFIG  NC_USER
  PAPRA_ARCHIVE_UID/GID    ownership for created files (default papra:papra)
  PAPRA_SYNC_DRY_RUN=1     report only, touch nothing
"""
import datetime
import grp
import json
import os
import pwd
import re
import shutil
import sqlite3
import subprocess
import sys
import unicodedata

import psycopg2

PAPRA_DB = os.environ.get("PAPRA_DB", "/var/lib/papra/db.sqlite")
DOCS_ROOT = os.environ.get("PAPRA_DOCUMENTS_ROOT", "/mnt/data/papra/documents")
ARCHIVE = os.environ.get("PAPRA_ARCHIVE_ROOT", "/mnt/data/papra-archive")
MOUNT = os.environ.get("PAPRA_ARCHIVE_MOUNT", "Papra")
STATE_DIR = os.environ.get("PAPRA_STATE_DIR", "/var/lib/papra-nc-sync")
OCC = os.environ.get("NC_OCC", "nextcloud-occ")
NC_USER = os.environ.get("NC_USER", "nsimon")
DRY_RUN = os.environ.get("PAPRA_SYNC_DRY_RUN") == "1"

MANIFEST = os.path.join(STATE_DIR, "manifest.json")

# Document-type tags, most specific first: the first one a document carries wins
# its folder. A doc tagged both "Facture" and "Facture télécom" files under the
# narrower one. Everything NOT in this list is a topic (Abonnement, Streaming,
# Assurance maladie, Impôts, …) and stays a systemtag — topics co-occur far too
# freely to be folders (of 455 docs only 49 carry a single tag).
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

# Types with no meaningful year: filing a passport under Passeport/2019/ is worse
# than Passeport/. These also happen to be most of the documents that carry no
# recoverable date at all, so the two problems cancel out.
UNDATED_TYPES = {"Carte d'identité", "Passeport", "RIB", "Bail", "Contrat"}

UNCLASSIFIED = "Non classé"
UNDATED_YEAR = "Sans date"

# Keep folder/file names safe for both Nextcloud and the Drive share.
_UNSAFE = re.compile(r'[/\\:*?"<>|\x00-\x1f]')


def safe_name(name, fallback="document"):
    name = unicodedata.normalize("NFC", name or "").strip().strip(".")
    name = _UNSAFE.sub("_", name)
    return name[:180] or fallback


def load_manifest():
    try:
        with open(MANIFEST) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_manifest(m):
    if DRY_RUN:
        return
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = MANIFEST + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(m, fh, indent=1, sort_keys=True, ensure_ascii=False)
    os.replace(tmp, MANIFEST)


def papra_documents():
    """All live documents with their tags, as {doc_id: {...}}."""
    con = sqlite3.connect(f"file:{PAPRA_DB}?mode=ro", uri=True)
    try:
        docs = {}
        for did, org, name, key, ddate in con.execute(
            "SELECT id, organization_id, original_name, original_storage_key, document_date "
            "FROM documents WHERE is_deleted = 0 AND deleted_at IS NULL"
        ):
            docs[did] = {"org": org, "name": name, "key": key, "date": ddate, "tags": []}
        for did, tag in con.execute(
            "SELECT dt.document_id, t.name FROM documents_tags dt JOIN tags t ON t.id = dt.tag_id"
        ):
            if did in docs:
                docs[did]["tags"].append(tag)
        return docs
    finally:
        con.close()


def classify(doc):
    """(type folder, year folder or None) for a document."""
    tags = set(doc["tags"])
    folder = next((t for t in TYPE_TAGS if t in tags), UNCLASSIFIED)
    if folder in UNDATED_TYPES:
        return folder, None
    ts = doc["date"]
    if not ts:
        return folder, UNDATED_YEAR
    # Papra stores epoch milliseconds in document_date.
    if ts > 1e11:
        ts //= 1000
    return folder, str(datetime.datetime.fromtimestamp(ts, datetime.UTC).year)


def target_rel(doc_id, doc, taken):
    """Relative archive path for a document, disambiguating filename clashes."""
    folder, year = classify(doc)
    parts = [safe_name(folder)] + ([safe_name(year)] if year else [])
    base = safe_name(doc["name"], fallback=doc_id)
    rel = os.path.join(*parts, base)
    if taken.get(rel) not in (None, doc_id):
        stem, ext = os.path.splitext(base)
        rel = os.path.join(*parts, f"{stem}-{doc_id[-6:]}{ext}")
    taken[rel] = doc_id
    return rel


def chown_tree(path, uid, gid):
    if uid is None or DRY_RUN:
        return
    try:
        os.chown(path, uid, gid)
    except OSError:
        pass


def place(docs, manifest, uid, gid):
    """Copy/move documents into their archive slot. Returns {doc_id: relpath}."""
    taken, placed = {}, {}
    # Existing placements first, so a document keeps its filename slot across runs
    # and only a genuine newcomer gets the -<suffix> disambiguator.
    for did, rel in manifest.items():
        if did in docs:
            taken[rel] = did
    copied = moved = 0
    for did, doc in sorted(docs.items()):
        rel = target_rel(did, doc, taken)
        dest = os.path.join(ARCHIVE, rel)
        prev = manifest.get(did)
        prev_abs = os.path.join(ARCHIVE, prev) if prev else None
        if prev == rel and os.path.exists(dest):
            placed[did] = rel
            continue
        if not DRY_RUN:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            chown_tree(os.path.dirname(dest), uid, gid)
        if prev_abs and os.path.exists(prev_abs):
            # Type or year changed (a re-tag, or a date finally resolved).
            if not DRY_RUN:
                shutil.move(prev_abs, dest)
            moved += 1
        else:
            src = os.path.join(DOCS_ROOT, doc["key"] or "")
            if not doc["key"] or not os.path.exists(src):
                print(f"[{did}] blob missing ({doc['key']!r}) — skip", flush=True)
                continue
            if not DRY_RUN:
                shutil.copy2(src, dest)
            copied += 1
        chown_tree(dest, uid, gid)
        placed[did] = rel
    return placed, copied, moved


def prune(placed):
    """Drop archive files no longer backed by a live Papra document."""
    keep = {os.path.join(ARCHIVE, rel) for rel in placed.values()}
    removed = 0
    for root, _dirs, files in os.walk(ARCHIVE):
        for f in files:
            p = os.path.join(root, f)
            if p not in keep:
                if not DRY_RUN:
                    os.unlink(p)
                removed += 1
    # Then any directory left empty by the pruning above.
    for root, dirs, files in os.walk(ARCHIVE, topdown=False):
        if root != ARCHIVE and not dirs and not files and not DRY_RUN:
            try:
                os.rmdir(root)
            except OSError:
                pass
    return removed


def nc_pg_password():
    # nextcloud-pg-password is postgres-owned; read the password out of
    # Nextcloud's own config.php instead.
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


def occ_scan():
    """Populate oc_filecache for the external mount so files have fileids."""
    if DRY_RUN:
        return
    subprocess.run(
        [OCC, "files:scan", "--path", f"/{NC_USER}/files/{MOUNT}", "--quiet"],
        check=False,
        stdout=subprocess.DEVNULL,
    )


def sync_tags(docs, placed):
    """Mirror every Papra tag onto the archive file as a Nextcloud systemtag."""
    conn = pg()
    conn.autocommit = True
    cur = conn.cursor()
    try:
        cur.execute(
            "SELECT numeric_id FROM oc_storages WHERE id = %s", (f"local::{ARCHIVE}/",)
        )
        row = cur.fetchone()
        if not row:
            print(
                f"archive storage 'local::{ARCHIVE}/' not in oc_storages — "
                "is the files_external mount configured and scanned? skipping tags",
                flush=True,
            )
            return 0, 0
        storage = row[0]

        # fileid by path, for this storage only. External-storage paths in
        # oc_filecache are relative to the mount root, i.e. "files/<rel>" is NOT
        # used here — local:: storages are rooted at the mount itself.
        cur.execute(
            "SELECT path, fileid FROM oc_filecache WHERE storage = %s", (storage,)
        )
        fileids = dict(cur.fetchall())

        tagids = {}

        def tagid(name):
            if name in tagids:
                return tagids[name]
            cur.execute(
                "SELECT id FROM oc_systemtag WHERE name = %s AND visibility = 1 LIMIT 1",
                (name,),
            )
            r = cur.fetchone()
            if r:
                tagids[name] = r[0]
            else:
                cur.execute(
                    "INSERT INTO oc_systemtag(name, visibility, editable) "
                    "VALUES(%s, 1, 1) RETURNING id",
                    (name,),
                )
                tagids[name] = cur.fetchone()[0]
            return tagids[name]

        # Every tag Papra knows about. Removals are restricted to this set, so a
        # tag a human added by hand in Nextcloud — which Papra has never heard of
        # — is never stripped off a file by this sweep.
        papra_owned = {tagid(t) for t in {t for d in docs.values() for t in d["tags"]}}

        tagged = missing = 0
        for did, rel in sorted(placed.items()):
            fid = fileids.get(rel)
            if fid is None:
                missing += 1
                continue
            want = {tagid(t) for t in docs[did]["tags"]}
            cur.execute(
                "SELECT systemtagid FROM oc_systemtag_object_mapping "
                "WHERE objecttype = 'files' AND objectid = %s",
                (str(fid),),
            )
            have = {r[0] for r in cur.fetchall()}
            for tid in want - have:
                if not DRY_RUN:
                    cur.execute(
                        "INSERT INTO oc_systemtag_object_mapping"
                        "(objectid, objecttype, systemtagid) VALUES(%s, 'files', %s)",
                        (str(fid), tid),
                    )
            for tid in (have & papra_owned) - want:
                if not DRY_RUN:
                    cur.execute(
                        "DELETE FROM oc_systemtag_object_mapping WHERE objecttype = 'files' "
                        "AND objectid = %s AND systemtagid = %s",
                        (str(fid), tid),
                    )
            tagged += 1
        return tagged, missing
    finally:
        conn.close()


def main():
    try:
        uid = pwd.getpwnam(os.environ.get("PAPRA_ARCHIVE_UID", "papra")).pw_uid
        gid = grp.getgrnam(os.environ.get("PAPRA_ARCHIVE_GID", "papra")).gr_gid
    except KeyError:
        uid = gid = None

    docs = papra_documents()
    if not docs:
        print("no documents in Papra — nothing to do", flush=True)
        return
    manifest = load_manifest()

    if not DRY_RUN:
        os.makedirs(ARCHIVE, exist_ok=True)
        chown_tree(ARCHIVE, uid, gid)

    placed, copied, moved = place(docs, manifest, uid, gid)
    removed = prune(placed)
    save_manifest(placed)
    occ_scan()
    tagged, missing = sync_tags(docs, placed)

    print(
        f"DONE {'(dry-run) ' if DRY_RUN else ''}"
        f"{len(placed)} filed (+{copied} copied, {moved} moved, {removed} pruned), "
        f"{tagged} tagged, {missing} awaiting scan",
        flush=True,
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001 — timer retries; don't mask the cause
        print(f"ERROR {type(e).__name__}: {e}", flush=True)
        sys.exit(1)
