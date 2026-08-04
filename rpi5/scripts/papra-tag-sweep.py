#!/usr/bin/env python3
"""Minimal safety-net: tag any UNTAGGED Papra docs on-prem via the beast-only
gate model, and backfill the document DATE that Papra leaves empty. Papra's
native auto-tagger is fire-once (no retry when beast is down); this timer
reconciles. It aborts on the first gate error (beast unreachable) and leaves the
rest untagged, so the backlog is picked up on the next run once beast is back ==
waits for beast. Runs as `papra` (clean SQLite writes); idempotent.

Dates: Papra declares a `document_date` column and never populates it — all 455
documents had it NULL — so anything grouping by year (papra-nc-sync's
<Type>/<Year>/ tree) would file a 2013 invoice under the import year. Two passes
fill it:
  1. FILENAME, no LLM. Covers ~74% and needs neither beast nor a gate call, so it
     still makes progress when beast is down.
  2. CONTENT, via the gate. Only for what pass 1 missed. This must NOT be a regex:
     a naive one reads the social-security number "1 96 11 29 260 237 85" on ameli
     attestations as 1996-11-29. The remaining ~7% genuinely carry no date at all
     (passport, ID card, RIB, bail) and are left NULL — papra-nc-sync files those
     types flat, with no year folder, so a NULL there costs nothing.

Tagging and dating share one gate call for documents that need both.
"""
import datetime
import json
import os
import re
import secrets
import sqlite3
import string
import sys
import time
import urllib.request

DB = os.environ.get("PAPRA_DB", "/var/lib/papra/db.sqlite")
GATE = os.environ.get("PAPRA_GATE_URL", "http://127.0.0.1:4001/v1/chat/completions")
MODEL = os.environ.get("PAPRA_TAG_MODEL", "qwen3-vl:8b")
MAX_TAGS, CAP, TIMEOUT = 6, 8000, 60
# Cap the per-run LLM date backfill so the first pass over a large archive spreads
# across timer runs instead of hammering beast for an hour.
DATE_BATCH = int(os.environ.get("PAPRA_DATE_BATCH", "40"))

con = sqlite3.connect(DB, timeout=30)
con.execute("PRAGMA busy_timeout=30000")
cur = con.cursor()


def ask(name, content, tagnames, sysp):
    schema = {"type": "object", "properties": {
        "existingTags": {"type": "array", "items": {"type": "string", "enum": tagnames}},
        "newTags": {"type": "array", "items": {"type": "object",
                    "properties": {"name": {"type": "string"}}, "required": ["name"]}},
        "documentDate": {"type": ["string", "null"]}},
        "required": ["existingTags", "newTags", "documentDate"]}
    body = json.dumps({"model": MODEL, "temperature": 0.2,
        "response_format": {"type": "json_schema", "json_schema": {"name": "tags", "strict": True, "schema": schema}},
        "messages": [{"role": "system", "content": sysp},
                     {"role": "user", "content": f"Nom: {name}\n\nContenu:\n{(content or '')[:CAP]}"}]}).encode()
    req = urllib.request.Request(GATE, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.loads(json.load(r)["choices"][0]["message"]["content"])


# ── document_date backfill ────────────────────────────────────────────────────
MIN_YEAR, MAX_YEAR = 1990, datetime.date.today().year

# Ordered most-specific-first. Compact forms (20171009, 201702) come first: they
# are unambiguous, and the separator forms would otherwise mis-split them.
DATE_PATTERNS = [
    r"(?<!\d)(?P<y>19[89]\d|20[0-3]\d)(?P<m>0[1-9]|1[0-2])(?P<d>0[1-9]|[12]\d|3[01])(?!\d)",
    r"(?P<y>19[89]\d|20[0-3]\d)[-_/.](?P<m>0[1-9]|1[0-2])[-_/.](?P<d>0[1-9]|[12]\d|3[01])(?!\d)",
    r"(?<!\d)(?P<d>0[1-9]|[12]\d|3[01])[-_/.](?P<m>0[1-9]|1[0-2])[-_/.](?P<y>19[89]\d|20[0-3]\d)(?!\d)",
    r"(?<!\d)(?P<y>19[89]\d|20[0-3]\d)(?P<m>0[1-9]|1[0-2])(?!\d)",
    r"(?P<y>19[89]\d|20[0-3]\d)[-_/.](?P<m>0[1-9]|1[0-2])(?!\d)",
    # Bare year. Deliberately NOT \b...\b: "_" is a word character, so \b never
    # fires against Papra's "__<N>" import suffix and "…LMDE 2018__4.pdf" would
    # go unmatched. Digit lookarounds are what we actually mean here.
    r"(?<!\d)(?P<y>19[89]\d|20[0-3]\d)(?!\d)",
]
DATE_RES = [re.compile(p) for p in DATE_PATTERNS]


def to_epoch_ms(y, m, d):
    try:
        if not MIN_YEAR <= y <= MAX_YEAR:
            return None
        return int(datetime.datetime(y, m, d, tzinfo=datetime.UTC).timestamp() * 1000)
    except ValueError:
        return None


def filename_date(name):
    """Date from a filename. Filenames are trustworthy; OCR body text is not."""
    for rx in DATE_RES:
        # First VALID match, not first match: a passport named "… - 2028.08.07"
        # leads with an out-of-range year, and we want to keep looking rather
        # than give up on the whole filename.
        for m in rx.finditer(name or ""):
            g = m.groupdict()
            ts = to_epoch_ms(int(g["y"]), int(g.get("m") or 1), int(g.get("d") or 1))
            if ts is not None:
                return ts
    return None


def parse_iso(s):
    m = re.match(r"\s*(\d{4})-(\d{2})-(\d{2})", s or "")
    return to_epoch_ms(*(int(x) for x in m.groups())) if m else None


def backfill_filename_dates():
    """Pass 1 — no LLM, so this makes progress even when beast is down."""
    rows = cur.execute(
        "SELECT id, name, original_name FROM documents "
        "WHERE deleted_at IS NULL AND document_date IS NULL").fetchall()
    n = 0
    for doc_id, name, original in rows:
        ts = filename_date(name) or filename_date(original)
        if ts is not None:
            cur.execute("UPDATE documents SET document_date=? WHERE id=?", (ts, doc_id))
            n += 1
    con.commit()
    return n, len(rows) - n


def backfill_llm_dates():
    """Pass 2 — ask the gate for whatever the filename couldn't give us."""
    rows = cur.execute(
        "SELECT id, name, content FROM documents "
        "WHERE deleted_at IS NULL AND document_date IS NULL "
        "ORDER BY length(content) ASC LIMIT ?", (DATE_BATCH,)).fetchall()
    sysp = ("Tu extrais la DATE d'un document personnel français (date d'émission, "
            "de facture ou de période concernée). Réponds au format AAAA-MM-JJ, ou null "
            "si le document ne porte aucune date. Attention: un numéro de sécurité "
            "sociale (ex. 1 96 11 29 260 237 85) n'est PAS une date.")
    schema = {"type": "object",
              "properties": {"documentDate": {"type": ["string", "null"]}},
              "required": ["documentDate"]}
    n = 0
    for doc_id, name, content in rows:
        body = json.dumps({"model": MODEL, "temperature": 0.0,
            "response_format": {"type": "json_schema",
                                "json_schema": {"name": "date", "strict": True, "schema": schema}},
            "messages": [{"role": "system", "content": sysp},
                         {"role": "user", "content": f"Nom: {name}\n\nContenu:\n{(content or '')[:CAP]}"}]}).encode()
        req = urllib.request.Request(GATE, data=body, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                data = json.loads(json.load(r)["choices"][0]["message"]["content"])
        except Exception as e:
            print(f"date backfill stopped: gate unreachable ({str(e)[:60]})", flush=True)
            break
        ts = parse_iso(data.get("documentDate") or "")
        if ts is not None:
            cur.execute("UPDATE documents SET document_date=? WHERE id=?", (ts, doc_id))
            n += 1
    con.commit()
    return n


def main():
    # Dates first, filename-only: cheap, offline, and papra-nc-sync needs them to
    # pick a year folder. Whatever it can't resolve falls to the LLM pass below.
    dated, undated = backfill_filename_dates()

    orgs = [r[0] for r in cur.execute("SELECT DISTINCT organization_id FROM documents WHERE deleted_at IS NULL")]
    ok = 0
    for org in orgs:
        tagmap, tagnames = {}, []
        for tid, nm, norm in cur.execute("SELECT id,name,normalized_name FROM tags WHERE organization_id=?", (org,)):
            tagmap[norm] = tid
            tagnames.append(nm)
        sysp = ("Tu catégorises des documents personnels français. Tags existants: " + ", ".join(tagnames) +
                ". Choisis uniquement les tags existants pertinents (peu = mieux, max " + str(MAX_TAGS) +
                "). Ne propose de nouveaux tags que si aucun existant ne convient. JSON, noms en français.")
        docs = cur.execute(
            "SELECT id,name,content FROM documents d WHERE d.organization_id=? AND d.deleted_at IS NULL "
            "AND NOT EXISTS(SELECT 1 FROM documents_tags dt WHERE dt.document_id=d.id) "
            "ORDER BY length(content) ASC", (org,)).fetchall()
        for doc_id, name, content in docs:
            try:
                data = ask(name, content, tagnames, sysp)
            except Exception as e:
                print(f"ABORT: gate/beast unreachable ({str(e)[:80]}); leaving backlog for next run", flush=True)
                con.close()
                sys.exit(75)  # EX_TEMPFAIL — timer retries; == waits for beast
            ids = []
            for nm in data.get("existingTags", []):
                t = tagmap.get(nm.lower().strip())
                if t:
                    ids.append(t)
            for nt in data.get("newTags", []):
                nm = (nt.get("name") or "").strip()
                if not nm:
                    continue
                norm = nm.lower()
                t = tagmap.get(norm)
                if not t:
                    t = "tag_" + "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(24))
                    now = int(time.time() * 1000)
                    cur.execute("INSERT INTO tags(id,created_at,updated_at,organization_id,name,color,description,normalized_name)"
                                " VALUES(?,?,?,?,?,?,?,?)", (t, now, now, org, nm, "#CCCCCC", None, norm))
                    tagmap[norm] = t
                    tagnames.append(nm)
                ids.append(t)
            for t in dict.fromkeys(ids):
                cur.execute("INSERT OR IGNORE INTO documents_tags(document_id,tag_id) VALUES(?,?)", (doc_id, t))
            # The tagging call already read the document, so take its date too
            # rather than spending a second call on it below.
            ts = parse_iso(data.get("documentDate") or "")
            if ts is not None:
                cur.execute(
                    "UPDATE documents SET document_date=? WHERE id=? AND document_date IS NULL",
                    (ts, doc_id))
            con.commit()
            ok += 1

    llm_dated = backfill_llm_dates() if undated else 0
    con.close()
    print(f"DONE swept {ok} untagged doc(s); dated {dated} from filename, "
          f"{llm_dated} via gate ({undated} were unresolved after pass 1)", flush=True)


if __name__ == "__main__":
    main()
