#!/usr/bin/env python3
"""On-prem, resumable Papra tag sweeper.

Papra's built-in ingest-time auto-tagger is disabled (AUTO_TAGGING_ENABLED=false)
because it runs in a fragile in-memory queue with no retry and its model routed
to a cloud fallback when beast was down. This sweeper is the single tagging path
instead: it reads UNTAGGED documents straight from the SQLite DB, asks the
beast-only gate model (qwen3-vl:8b, strict json_schema, French) for tags, and
writes them into documents_tags (creating new tags, deduped).

Design goals:
  * On-prem only  — the gate model has no cloud fallback, so if beast is down the
    request errors; we never mis-tag sensitive docs via a cloud model.
  * Never lose work — idempotent, only touches untagged docs; a doc left untagged
    (beast down) is simply retried on the next timer run == "waits for beast".
  * Fail fast/clean — 60s per-request timeout + a consecutive-failure circuit
    breaker so a beast outage aborts the run quickly instead of hammering it.

Config via env (all optional):
  PAPRA_DB       default /var/lib/papra/db.sqlite
  PAPRA_GATE_URL default http://127.0.0.1:4001/v1/chat/completions
  PAPRA_TAG_MODEL default qwen3-vl:8b
"""
import json
import os
import sqlite3
import secrets
import string
import sys
import time
import urllib.request

DB = os.environ.get("PAPRA_DB", "/var/lib/papra/db.sqlite")
GATE = os.environ.get("PAPRA_GATE_URL", "http://127.0.0.1:4001/v1/chat/completions")
MODEL = os.environ.get("PAPRA_TAG_MODEL", "qwen3-vl:8b")
MAX_TAGS = 6
CONTENT_CAP = 8000       # chars; keeps the prompt small/fast, plenty to categorise
REQ_TIMEOUT = 60         # seconds; a stuck request fails fast instead of pinning beast
MAX_CONSEC = 5           # consecutive failures => assume beast down, abort this run


def new_tag_id():
    return "tag_" + "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(24))


def tag_one(cur, org, tagmap, tagnames, schema, sys_prompt, doc_id, name, content):
    body = {
        "model": MODEL,
        "response_format": {"type": "json_schema",
                            "json_schema": {"name": "tags", "strict": True, "schema": schema}},
        "temperature": 0.2,
        "messages": [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": f"Nom du fichier: {name}\n\nContenu:\n{(content or '')[:CONTENT_CAP]}"},
        ],
    }
    req = urllib.request.Request(GATE, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=REQ_TIMEOUT) as r:
        out = json.load(r)
    data = json.loads(out["choices"][0]["message"]["content"])

    ids = []
    for nm in data.get("existingTags", []):
        tid = tagmap.get(nm.lower().strip())
        if tid:
            ids.append(tid)
    for nt in data.get("newTags", []):
        nm = (nt.get("name") or "").strip()
        if not nm:
            continue
        norm = nm.lower()
        tid = tagmap.get(norm)
        if not tid:
            tid = new_tag_id()
            now = int(time.time() * 1000)
            cur.execute(
                "INSERT INTO tags(id,created_at,updated_at,organization_id,name,color,description,normalized_name)"
                " VALUES(?,?,?,?,?,?,?,?)",
                (tid, now, now, org, nm, "#CCCCCC", None, norm),
            )
            tagmap[norm] = tid
            tagnames.append(nm)
        ids.append(tid)

    seen, final = set(), []
    for t in ids:
        if t not in seen:
            seen.add(t)
            final.append(t)
        if len(final) >= MAX_TAGS:
            break
    for tid in final:
        cur.execute("INSERT OR IGNORE INTO documents_tags(document_id,tag_id) VALUES(?,?)", (doc_id, tid))
    return [n for n in data.get("existingTags", [])] + [nt.get("name") for nt in data.get("newTags", [])]


def main():
    con = sqlite3.connect(DB, timeout=30)
    con.execute("PRAGMA busy_timeout=30000")
    cur = con.cursor()

    orgs = [r[0] for r in cur.execute(
        "SELECT DISTINCT organization_id FROM documents WHERE deleted_at IS NULL"
    ).fetchall()]

    grand_ok = grand_fail = 0
    t0 = time.time()
    for org in orgs:
        tagmap, tagnames = {}, []
        for tid, nm, norm in cur.execute(
            "SELECT id,name,normalized_name FROM tags WHERE organization_id=?", (org,)
        ):
            tagmap[norm] = tid
            tagnames.append(nm)

        schema = {
            "type": "object",
            "properties": {
                "existingTags": {"type": "array", "items": {"type": "string", "enum": tagnames}},
                "newTags": {"type": "array", "items": {"type": "object",
                            "properties": {"name": {"type": "string"}}, "required": ["name"]}},
            },
            "required": ["existingTags", "newTags"],
        }
        sys_prompt = (
            "Tu catégorises des documents personnels français. Tags existants "
            "disponibles: " + ", ".join(tagnames) + ". Choisis uniquement les tags "
            "existants réellement pertinents (peu = mieux, maximum " + str(MAX_TAGS) +
            "). Ne propose de nouveaux tags que si aucun existant ne convient. "
            "Réponds en JSON, noms de tags en français."
        )

        docs = cur.execute(
            "SELECT id,name,content FROM documents d WHERE d.organization_id=? "
            "AND d.deleted_at IS NULL "
            "AND NOT EXISTS(SELECT 1 FROM documents_tags dt WHERE dt.document_id=d.id) "
            "ORDER BY length(content) ASC", (org,)
        ).fetchall()
        if not docs:
            continue
        print(f"[{org}] untagged: {len(docs)}", flush=True)

        consec = 0
        for i, (doc_id, name, content) in enumerate(docs, 1):
            try:
                tags = tag_one(cur, org, tagmap, tagnames, schema, sys_prompt, doc_id, name, content)
                con.commit()
                grand_ok += 1
                consec = 0
                if i % 10 == 0 or i <= 3:
                    print(f"  [{i}/{len(docs)}] ok -> {tags}", flush=True)
            except Exception as e:
                grand_fail += 1
                consec += 1
                print(f"  [{i}/{len(docs)}] FAIL {str(name)[:40]}: {str(e)[:120]}", flush=True)
                if consec >= MAX_CONSEC:
                    print(f"ABORT: {consec} consecutive failures — beast likely down. "
                          f"Leaving remaining docs untagged; the next timer run will retry.", flush=True)
                    con.close()
                    print(f"DONE ok={grand_ok} fail={grand_fail} elapsed={int(time.time()-t0)}s aborted=1", flush=True)
                    # Non-zero exit so the failure is visible in `systemctl status`,
                    # but the timer keeps firing so it simply retries next cycle.
                    sys.exit(75)  # EX_TEMPFAIL

    con.close()
    print(f"DONE ok={grand_ok} fail={grand_fail} elapsed={int(time.time()-t0)}s aborted=0", flush=True)


if __name__ == "__main__":
    main()
