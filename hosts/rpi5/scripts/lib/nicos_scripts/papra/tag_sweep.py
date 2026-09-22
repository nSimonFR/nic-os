#!/usr/bin/env python3
"""Minimal safety-net: tag any UNTAGGED Papra docs on-prem via the beast-only
gate model, and backfill the `document_date` Papra leaves empty. Papra's native
auto-tagger is fire-once (no retry when beast is down); this timer reconciles. It
aborts on the first gate error (beast unreachable) and leaves the rest, so the
backlog is picked up on the next run once beast is back == waits for beast. Runs
as `papra` (clean SQLite writes); idempotent.

Dates (papra.nc_sync files by <Type>/<Year>/, and Papra never sets the column):
  1. filename, no LLM — covers ~84%, so it progresses while beast is down;
  2. content, via the gate — asked once per document, remembered in STATE_DIR,
     since the ~7% with no date at all would otherwise be re-asked every run.

Config via environment:
  PAPRA_DB          sqlite path              (default /var/lib/papra/db.sqlite)
  PAPRA_GATE_URL    OpenAI-shaped endpoint   (default the local tiny-llm-gate)
  PAPRA_TAG_MODEL   model id                 (default qwen3-vl:8b)
  PAPRA_DATE_BATCH  gate date lookups per run (default 40)
  STATE_DIR         where the dated-by-gate set lives (unset: not remembered)
"""

import datetime
import json
import os
import re
import secrets as _secrets
import sqlite3
import string
import sys
import time
import urllib.request
from dataclasses import dataclass

from ..secrets import env_int, env_str
from ..state import load_json, save_json

DEFAULT_DB = "/var/lib/papra/db.sqlite"
DEFAULT_GATE = "http://127.0.0.1:4001/v1/chat/completions"
DEFAULT_MODEL = "qwen3-vl:8b"

MAX_TAGS, CAP, TIMEOUT = 6, 8000, 60
DATE_BATCH = 40
MIN_YEAR = 1990

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
    date_batch: int = DATE_BATCH
    state_dir: str = ""

    @classmethod
    def from_env(cls, env=None):
        return cls(
            db=env_str("PAPRA_DB", DEFAULT_DB, env),
            gate=env_str("PAPRA_GATE_URL", DEFAULT_GATE, env),
            model=env_str("PAPRA_TAG_MODEL", DEFAULT_MODEL, env),
            max_tags=env_int("PAPRA_MAX_TAGS", MAX_TAGS, env),
            date_batch=env_int("PAPRA_DATE_BATCH", DATE_BATCH, env),
            state_dir=env_str("STATE_DIR", "", env),
        )


DATE_FIELD = {"documentDate": {"type": ["string", "null"]}}


def tag_schema(tagnames):
    """The strict JSON schema the model must answer in.

    `existingTags` is an enum over the org's current tags, so the model cannot
    invent a tag id — new tags have to come through `newTags` and get created here.
    The date rides along, so a document needing both costs one call.
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
            **DATE_FIELD,
        },
        "required": ["existingTags", "newTags", "documentDate"],
    }


DATE_SCHEMA = {"type": "object", "properties": DATE_FIELD, "required": ["documentDate"]}

DATE_RULE = (
    "Date du document (émission, facture ou période concernée) au format "
    "AAAA-MM-JJ, ou null s'il n'en porte aucune. Un numéro de sécurité sociale "
    "(ex. 1 96 11 29 260 237 85) n'est PAS une date."
)


def system_prompt(tagnames, max_tags=MAX_TAGS):
    return (
        "Tu catégorises des documents personnels français. Tags existants: "
        + ", ".join(tagnames)
        + ". Choisis uniquement les tags existants pertinents (peu = mieux, max "
        + str(max_tags)
        + "). Ne propose de nouveaux tags que si aucun existant ne convient. "
        "JSON, noms en français. " + DATE_RULE
    )


def _chat(cfg, sysp, name, content, schema_name, schema, temperature, opener=None):
    body = json.dumps({
        "model": cfg.model,
        "temperature": temperature,
        "response_format": {"type": "json_schema", "json_schema": {
            "name": schema_name, "strict": True, "schema": schema}},
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


def ask(cfg, name, content, tagnames, sysp, opener=None):
    return _chat(cfg, sysp, name, content, "tags", tag_schema(tagnames), 0.2, opener)


def ask_date(cfg, name, content, opener=None):
    sysp = "Tu extrais la date d'un document personnel français. " + DATE_RULE
    return _chat(cfg, sysp, name, content, "date", DATE_SCHEMA, 0.0, opener)


# ── document_date ─────────────────────────────────────────────────────────────

_Y = r"(?P<y>19[89]\d|20[0-3]\d)"
_M = r"(?P<m>0[1-9]|1[0-2])"
_D = r"(?P<d>0[1-9]|[12]\d|3[01])"
_S = r"[-_/.]"
# Most specific first; compact forms before separated ones, which would mis-split
# them. Digit lookarounds rather than \b: "_" is a word char, so \b never fires
# against Papra's "__<N>" import suffix ("…LMDE 2018__4.pdf").
DATE_RES = [re.compile(p) for p in (
    rf"(?<!\d){_Y}{_M}{_D}(?!\d)",
    rf"{_Y}{_S}{_M}{_S}{_D}(?!\d)",
    rf"(?<!\d){_D}{_S}{_M}{_S}{_Y}(?!\d)",
    rf"(?<!\d){_Y}{_M}(?!\d)",
    rf"{_Y}{_S}{_M}(?!\d)",
    rf"(?<!\d){_Y}(?!\d)",
)]


def to_epoch_ms(y, m, d, max_year=None):
    """Papra stores `document_date` as epoch milliseconds. None if implausible."""
    if not MIN_YEAR <= y <= (max_year or datetime.date.today().year):
        return None
    try:
        return int(datetime.datetime(y, m, d, tzinfo=datetime.UTC).timestamp() * 1000)
    except ValueError:
        return None


def filename_date(name, max_year=None):
    for rx in DATE_RES:
        # First VALID match: "Passeport - 2028.08.07" leads with an expiry year.
        for m in rx.finditer(name or ""):
            g = m.groupdict()
            ts = to_epoch_ms(int(g["y"]), int(g.get("m") or 1), int(g.get("d") or 1),
                             max_year)
            if ts is not None:
                return ts
    return None


def parse_iso(s, max_year=None):
    m = re.match(r"\s*(\d{4})-(\d{2})-(\d{2})", s or "")
    return to_epoch_ms(*(int(x) for x in m.groups()), max_year) if m else None


def set_date(cur, doc_id, ts):
    cur.execute(
        "UPDATE documents SET document_date=? WHERE id=? AND document_date IS NULL",
        (ts, doc_id))


def backfill_filename_dates(con):
    """-> (dated, still undated). No gate call."""
    cur = con.cursor()
    rows = cur.execute(
        "SELECT id, name, original_name FROM documents "
        "WHERE deleted_at IS NULL AND document_date IS NULL").fetchall()
    n = 0
    for doc_id, name, original in rows:
        ts = filename_date(name) or filename_date(original)
        if ts is not None:
            set_date(cur, doc_id, ts)
            n += 1
    con.commit()
    return n, len(rows) - n


def backfill_gate_dates(cfg, con, tried, ask_fn=None):
    """Ask the gate for up to `date_batch` undated docs not already in `tried`.

    Mutates `tried` so the caller can persist it even if this raises.
    """
    ask_fn = ask_fn or (lambda *a: ask_date(cfg, *a))
    cur = con.cursor()
    rows = cur.execute(
        "SELECT id, name, content FROM documents "
        "WHERE deleted_at IS NULL AND document_date IS NULL "
        "ORDER BY length(content) ASC").fetchall()
    n = asked = 0
    for doc_id, name, content in rows:
        if doc_id in tried:
            continue
        if asked >= cfg.date_batch:
            break
        try:
            data = ask_fn(name, content)
        except Exception as e:  # noqa: BLE001 - any gate failure is "beast is away"
            raise GateUnreachable(str(e)[:80]) from e
        asked += 1
        tried.add(doc_id)
        ts = parse_iso(data.get("documentDate"))
        if ts is not None:
            set_date(cur, doc_id, ts)
            con.commit()
            n += 1
    return n


# ── tags ──────────────────────────────────────────────────────────────────────


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


def sweep(cfg, con, ask_fn=None, now=None, rand=None, tried=None):
    """Tag every untagged document. -> count tagged.

    The tag call already asked for the date, so each doc goes into `tried` too.

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
            ts = parse_iso(data.get("documentDate"))
            if ts is not None:
                set_date(cur, doc_id, ts)
            if tried is not None:
                tried.add(doc_id)
            con.commit()
            ok += 1
    return ok


def main(env=None, con=None, ask_fn=None, ask_date_fn=None):
    cfg = Config.from_env(env)
    # Opened here, not at import: the old module-level connect() is what made this
    # file impossible to import (let alone test) anywhere but the live host.
    if con is None:
        con = sqlite3.connect(cfg.db, timeout=30)
        con.execute("PRAGMA busy_timeout=30000")
    tried_path = os.path.join(cfg.state_dir, "date-asked.json") if cfg.state_dir else None
    tried = set(load_json(tried_path, [])) if tried_path else set()
    ok = gate_dated = 0
    try:
        dated, undated = backfill_filename_dates(con)
        ok = sweep(cfg, con, ask_fn=ask_fn, tried=tried)
        if undated:
            gate_dated = backfill_gate_dates(cfg, con, tried, ask_fn=ask_date_fn)
    except GateUnreachable as e:
        print(f"ABORT: gate/beast unreachable ({e}); leaving backlog for next run",
              flush=True)
        return EX_TEMPFAIL
    finally:
        if tried_path:
            save_json(tried_path, sorted(tried))
        con.close()
    print(f"DONE swept {ok} untagged doc(s); dated {dated} from filename, "
          f"{gate_dated} via gate", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
