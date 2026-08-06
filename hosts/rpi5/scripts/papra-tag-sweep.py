#!/usr/bin/env python3
"""Minimal safety-net: tag any UNTAGGED Papra docs on-prem via the beast-only
gate model. Papra's native auto-tagger is fire-once (no retry when beast is down);
this timer reconciles. It aborts on the first gate error (beast unreachable) and
leaves the rest untagged, so the backlog is picked up on the next run once beast
is back == waits for beast. Runs as `papra` (clean SQLite writes); idempotent.

(NC systemtag mirroring only happens for docs tagged by Papra's native tagger,
which fires the webhook — docs recovered by this sweep are tagged in Papra but not
auto-mirrored to Nextcloud.)
"""
import json
import os
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

con = sqlite3.connect(DB, timeout=30)
con.execute("PRAGMA busy_timeout=30000")
cur = con.cursor()


def ask(name, content, tagnames, sysp):
    schema = {"type": "object", "properties": {
        "existingTags": {"type": "array", "items": {"type": "string", "enum": tagnames}},
        "newTags": {"type": "array", "items": {"type": "object",
                    "properties": {"name": {"type": "string"}}, "required": ["name"]}}},
        "required": ["existingTags", "newTags"]}
    body = json.dumps({"model": MODEL, "temperature": 0.2,
        "response_format": {"type": "json_schema", "json_schema": {"name": "tags", "strict": True, "schema": schema}},
        "messages": [{"role": "system", "content": sysp},
                     {"role": "user", "content": f"Nom: {name}\n\nContenu:\n{(content or '')[:CAP]}"}]}).encode()
    req = urllib.request.Request(GATE, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.loads(json.load(r)["choices"][0]["message"]["content"])


def main():
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
            con.commit()
            ok += 1
    con.close()
    print(f"DONE swept {ok} untagged doc(s)", flush=True)


if __name__ == "__main__":
    main()
