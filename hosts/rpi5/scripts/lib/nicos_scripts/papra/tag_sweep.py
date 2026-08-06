#!/usr/bin/env python3
"""Minimal safety-net: tag any UNTAGGED Papra docs on-prem via the beast-only
gate model. Papra's native auto-tagger is fire-once (no retry when beast is down);
this timer reconciles. It aborts on the first gate error (beast unreachable) and
leaves the rest untagged, so the backlog is picked up on the next run once beast
is back == waits for beast. Runs as `papra` (clean SQLite writes); idempotent.

(NC systemtag mirroring only happens for docs tagged by Papra's native tagger,
which fires the webhook — docs recovered by this sweep are tagged in Papra but not
auto-mirrored to Nextcloud.)

Config via environment:
  PAPRA_DB          sqlite path              (default /var/lib/papra/db.sqlite)
  PAPRA_GATE_URL    OpenAI-shaped endpoint   (default the local tiny-llm-gate)
  PAPRA_TAG_MODEL   model id                 (default qwen3-vl:8b)
"""

import json
import secrets as _secrets
import sqlite3
import string
import sys
import time
import urllib.request
from dataclasses import dataclass

from ..secrets import env_int, env_str

DEFAULT_DB = "/var/lib/papra/db.sqlite"
DEFAULT_GATE = "http://127.0.0.1:4001/v1/chat/completions"
DEFAULT_MODEL = "qwen3-vl:8b"

MAX_TAGS, CAP, TIMEOUT = 6, 8000, 60

# EX_TEMPFAIL: tells systemd this was transient. The timer retries, which is how
# "wait for beast to come back" is expressed.
EX_TEMPFAIL = 75


class GateUnreachable(Exception):
    """beast/the gate did not answer. The backlog stays untagged, deliberately."""


@dataclass(frozen=True)
class Config:
    db: str = DEFAULT_DB
    gate: str = DEFAULT_GATE
    model: str = DEFAULT_MODEL
    max_tags: int = MAX_TAGS
    cap: int = CAP
    timeout: int = TIMEOUT

    @classmethod
    def from_env(cls, env=None):
        return cls(
            db=env_str("PAPRA_DB", DEFAULT_DB, env),
            gate=env_str("PAPRA_GATE_URL", DEFAULT_GATE, env),
            model=env_str("PAPRA_TAG_MODEL", DEFAULT_MODEL, env),
            max_tags=env_int("PAPRA_MAX_TAGS", MAX_TAGS, env),
        )


def tag_schema(tagnames):
    """The strict JSON schema the model must answer in.

    `existingTags` is an enum over the org's current tags, so the model cannot
    invent a tag id — new tags have to come through `newTags` and get created here.
    """
    return {
        "type": "object",
        "properties": {
            "existingTags": {"type": "array", "items": {"type": "string", "enum": tagnames}},
            "newTags": {"type": "array", "items": {
                "type": "object",
                "properties": {"name": {"type": "string"}},
                "required": ["name"],
            }},
        },
        "required": ["existingTags", "newTags"],
    }


def system_prompt(tagnames, max_tags=MAX_TAGS):
    return (
        "Tu catégorises des documents personnels français. Tags existants: "
        + ", ".join(tagnames)
        + ". Choisis uniquement les tags existants pertinents (peu = mieux, max "
        + str(max_tags)
        + "). Ne propose de nouveaux tags que si aucun existant ne convient. "
        "JSON, noms en français."
    )


def ask(cfg, name, content, tagnames, sysp, opener=None):
    body = json.dumps({
        "model": cfg.model,
        "temperature": 0.2,
        "response_format": {"type": "json_schema", "json_schema": {
            "name": "tags", "strict": True, "schema": tag_schema(tagnames)}},
        "messages": [
            {"role": "system", "content": sysp},
            {"role": "user",
             "content": f"Nom: {name}\n\nContenu:\n{(content or '')[:cfg.cap]}"},
        ],
    }).encode()
    req = urllib.request.Request(
        cfg.gate, data=body, headers={"Content-Type": "application/json"})
    with (opener or urllib.request.urlopen)(req, timeout=cfg.timeout) as r:
        return json.loads(json.load(r)["choices"][0]["message"]["content"])


def new_tag_id(rand=None):
    """Papra tag ids are `tag_` + 24 url-safe chars, generated client-side."""
    pick = rand or (lambda alphabet: _secrets.choice(alphabet))
    alphabet = string.ascii_lowercase + string.digits
    return "tag_" + "".join(pick(alphabet) for _ in range(24))


def untagged_docs(cur, org):
    """Docs with no tag at all, smallest first — cheapest prompts land first, so a
    gate that dies mid-sweep has still cleared the most documents it could."""
    return cur.execute(
        "SELECT id,name,content FROM documents d WHERE d.organization_id=? AND d.deleted_at IS NULL "
        "AND NOT EXISTS(SELECT 1 FROM documents_tags dt WHERE dt.document_id=d.id) "
        "ORDER BY length(content) ASC", (org,)).fetchall()


def apply_tags(cur, org, doc_id, data, tagmap, tagnames, now_ms, rand=None):
    """Resolve the model's answer to tag ids, creating any genuinely new tag.

    Mutates `tagmap`/`tagnames` so a tag invented for one document is reused by the
    next rather than created twice.
    """
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
            t = new_tag_id(rand)
            cur.execute(
                "INSERT INTO tags(id,created_at,updated_at,organization_id,name,color,description,normalized_name)"
                " VALUES(?,?,?,?,?,?,?,?)",
                (t, now_ms, now_ms, org, nm, "#CCCCCC", None, norm))
            tagmap[norm] = t
            tagnames.append(nm)
        ids.append(t)
    for t in dict.fromkeys(ids):
        cur.execute(
            "INSERT OR IGNORE INTO documents_tags(document_id,tag_id) VALUES(?,?)",
            (doc_id, t))
    return list(dict.fromkeys(ids))


def sweep(cfg, con, ask_fn=None, now=None, rand=None):
    """Tag every untagged document. -> count tagged.

    Raises GateUnreachable on the first gate failure, having committed everything
    tagged up to that point (each document is its own transaction).
    """
    ask_fn = ask_fn or (lambda *a: ask(cfg, *a))
    now_ms = now if now is not None else int(time.time() * 1000)
    cur = con.cursor()
    orgs = [r[0] for r in cur.execute(
        "SELECT DISTINCT organization_id FROM documents WHERE deleted_at IS NULL")]
    ok = 0
    for org in orgs:
        tagmap, tagnames = {}, []
        for tid, nm, norm in cur.execute(
            "SELECT id,name,normalized_name FROM tags WHERE organization_id=?", (org,)
        ):
            tagmap[norm] = tid
            tagnames.append(nm)
        sysp = system_prompt(tagnames, cfg.max_tags)
        for doc_id, name, content in untagged_docs(cur, org):
            try:
                data = ask_fn(name, content, tagnames, sysp)
            except Exception as e:  # noqa: BLE001 - any gate failure is "beast is away"
                raise GateUnreachable(str(e)[:80]) from e
            apply_tags(cur, org, doc_id, data, tagmap, tagnames, now_ms, rand)
            con.commit()
            ok += 1
    return ok


def main(env=None, con=None):
    cfg = Config.from_env(env)
    # Opened here, not at import: the old module-level connect() is what made this
    # file impossible to import (let alone test) anywhere but the live host.
    if con is None:
        con = sqlite3.connect(cfg.db, timeout=30)
        con.execute("PRAGMA busy_timeout=30000")
    try:
        ok = sweep(cfg, con)
    except GateUnreachable as e:
        print(f"ABORT: gate/beast unreachable ({e}); leaving backlog for next run",
              flush=True)
        return EX_TEMPFAIL
    finally:
        con.close()
    print(f"DONE swept {ok} untagged doc(s)", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
