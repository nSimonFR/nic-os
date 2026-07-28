#!/usr/bin/env python3
"""Moxfield -> ShowMyCards deck sync, plus ShowMyCards -> file export.

PULL is authoritative for deck CONTENTS: Moxfield is where decks are edited, so a
run reconciles each ShowMyCards list to match its Moxfield deck. ShowMyCards stays
authoritative for physical storage (binders/boxes), which Moxfield cannot express.

PUSH is deliberately file-based, not API-based. Moxfield write endpoints require a
Bearer token whose issuing endpoint (POST /v2/account/token) is gated by a
Cloudflare Turnstile CAPTCHA that cannot be solved server-side -- see the open
report from a developer with a whitelisted User-Agent on Moxfield's own tracker,
moxfield/moxfield-public#143 -- and their ToS forbids automated access without
written permission. So we generate files the user uploads by hand.

Ownership (`collected_quantity`) is counted at ORACLE level, not per printing: any
printing in any finish satisfies a deck slot, because what matters is whether the
card is in the box. Printings of one oracle card share one pool within a deck, so
8 Forests wanted across two printings with 5 owned is 5 collected, not 5 + 5.
Pools are NOT shared between decks -- each deck answers "can I build this one",
so a single physical copy legitimately counts in every deck that wants it.

Reconciliation is diff-based (add / update / delete per item) rather than
delete-and-recreate, because ShowMyCards' /api/data/import is additive-only and has
no replace mode: re-importing duplicates everything.

Env contract (all set by rpi5/moxfield-sync.nix):
  MOXFIELD_DECK_IDS   comma-separated Moxfield publicIds
  MOXFIELD_USER_AGENT honest UA naming the project + a contact URL
  SMC_API             ShowMyCards API base, e.g. http://127.0.0.1:8330/api
  SMC_DB              read-only sqlite path, for oracle_id lookups
  EXPORT_DIR          where collection.csv + deck .txt files are written
  STATE_DIR           per-deck content hashes, to skip unchanged decks
  DRY_RUN             "1" (default) logs planned mutations without applying them
"""

import csv
import hashlib
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request

MOX_API = "https://api2.moxfield.com/v3/decks/all/"
DECK_BOARDS = ("commanders", "mainboard")  # the deck proper; sideboard/maybeboard reported only
FETCH_DELAY = 3.0  # seconds between Moxfield fetches; their rate limit is unpublished

DECK_IDS = [d.strip() for d in os.environ.get("MOXFIELD_DECK_IDS", "").split(",") if d.strip()]
USER_AGENT = os.environ.get("MOXFIELD_USER_AGENT", "nic-os-moxfield-sync/1.0")
SMC = os.environ.get("SMC_API", "http://127.0.0.1:8330/api").rstrip("/")
DB = os.environ.get("SMC_DB", "/mnt/data/showmycards/database.db")
EXPORT_DIR = os.environ.get("EXPORT_DIR", "/mnt/data/moxfield-export")
STATE_DIR = os.environ.get("STATE_DIR", "/var/lib/moxfield-sync")
DRY_RUN = os.environ.get("DRY_RUN", "1") != "0"

LANG_NAME = {"en": "English", "fr": "French"}


def log(msg):
    print(f"[moxfield-sync] {msg}", flush=True)


# ── HTTP ────────────────────────────────────────────────────────────────────────

def _request(url, method="GET", body=None, timeout=120, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    hdrs = {"Accept": "application/json"}
    if data:
        hdrs["Content-Type"] = "application/json"
    hdrs.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


def moxfield_deck(public_id):
    """Fetch one deck, backing off on 429/5xx. Moxfield publishes no rate limit, so
    be conservative: serial fetches, generous delay, exponential retry."""
    url = MOX_API + public_id
    for attempt in range(5):
        try:
            return _request(url, headers={"User-Agent": USER_AGENT})
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt < 4:
                wait = 5 * (2 ** attempt)
                log(f"  {public_id}: HTTP {e.code}, retrying in {wait}s")
                time.sleep(wait)
                continue
            raise
        except urllib.error.URLError as e:
            if attempt < 4:
                wait = 5 * (2 ** attempt)
                log(f"  {public_id}: {e.reason}, retrying in {wait}s")
                time.sleep(wait)
                continue
            raise
    raise RuntimeError(f"unreachable: {public_id}")


def smc(path, method="GET", body=None):
    # First call after idle wakes the socket-activated chain and waits on the
    # ready probe, which can take ~60s -- hence the long timeout.
    return _request(f"{SMC}{path}", method=method, body=body, timeout=180)


# ── local catalogue ─────────────────────────────────────────────────────────────

def open_db():
    return sqlite3.connect(f"file:{DB}?mode=ro", uri=True)


def oracle_ids(con, scryfall_ids):
    """Moxfield omits oracle_id but ShowMyCards requires it, so resolve locally."""
    out = {}
    ids = list(scryfall_ids)
    for i in range(0, len(ids), 400):
        chunk = ids[i:i + 400]
        q = f"select scryfall_id, oracle_id from cards where scryfall_id in ({','.join('?' * len(chunk))})"
        for sid, oid in con.execute(q, chunk):
            if oid:
                out[sid] = oid
    return out


def owned_by_oracle(con):
    """Ownership per oracle card, collapsing printing AND finish. Keying on the
    printing instead is what made the Pixie Dust deck report 54/100 while every
    card in it was sitting in a binder."""
    owned = {}
    for oid, qty in con.execute(
        "select c.oracle_id, sum(i.quantity) from inventories i"
        " join cards c on c.scryfall_id = i.scryfall_id"
        " where c.oracle_id is not null group by 1"
    ):
        owned[oid] = qty
    return owned


# ── deck parsing ────────────────────────────────────────────────────────────────

def parse_deck(deck):
    """-> (wanted{(scryfall_id,treatment): qty}, excluded{board: count})"""
    wanted, excluded = {}, {}
    for board, bd in (deck.get("boards") or {}).items():
        count = bd.get("count") or 0
        if board not in DECK_BOARDS:
            if count:
                excluded[board] = count
            continue
        for entry in (bd.get("cards") or {}).values():
            card = entry.get("card") or {}
            sid = card.get("scryfall_id")
            if not sid:
                continue
            treat = "foil" if entry.get("isFoil") else "nonfoil"
            wanted[(sid, treat)] = wanted.get((sid, treat), 0) + int(entry.get("quantity", 1))
    return wanted, excluded


def deck_fingerprint(wanted, name):
    payload = json.dumps({"n": name, "c": sorted([[k[0], k[1], v] for k, v in wanted.items()])},
                         sort_keys=True)
    return hashlib.sha256(payload.encode()).hexdigest()


def allocate_collected(wanted, oids, owned):
    """-> {(scryfall_id,treatment): collected_qty}

    Cannot be a per-item min(): two items of the same oracle card (the basic-land
    case, or one deck listing two printings of a staple) would each claim the full
    pool and over-report. So walk the items in a deterministic order and draw down
    a shared per-oracle pool."""
    pool, collected = {}, {}
    for key in sorted(wanted):
        oid = oids.get(key[0])
        if not oid:
            continue  # not in the local catalogue; reconcile() skips it and says so
        if oid not in pool:
            pool[oid] = owned.get(oid, 0)
        take = min(wanted[key], pool[oid])
        collected[key] = take
        pool[oid] -= take
    return collected


# ── ShowMyCards reconciliation ──────────────────────────────────────────────────

def find_list(lists, public_id, name):
    """Match on the Moxfield URL kept in the list description; fall back to name so
    a list created by hand is still adopted rather than duplicated."""
    for lst in lists:
        if public_id and public_id in (lst.get("description") or ""):
            return lst
    for lst in lists:
        if (lst.get("name") or "").strip() == name.strip():
            return lst
    return None


def list_items(list_id):
    items, page = [], 1
    while True:
        resp = smc(f"/lists/{list_id}/items?page={page}&page_size=100")
        items += resp.get("data") or []
        if page >= (resp.get("total_pages") or 1):
            return items
        page += 1


def reconcile(list_id, wanted, oids, collected_by_key):
    """Bring one list's items in line with `wanted`. Returns (added, updated, removed)."""
    current = {}
    for it in list_items(list_id):
        current[(it["scryfall_id"], it.get("treatment") or "nonfoil")] = it

    add, update, remove = [], [], []
    for key, qty in wanted.items():
        sid, treat = key
        oid = oids.get(sid)
        if not oid:
            log(f"  ! {sid} not in local catalogue (non-en/fr printing?) — skipping")
            continue
        collected = collected_by_key.get(key, 0)
        cur = current.get(key)
        if cur is None:
            add.append({"scryfall_id": sid, "oracle_id": oid, "treatment": treat,
                        "desired_quantity": qty})
        elif cur["desired_quantity"] != qty or cur.get("collected_quantity", 0) != collected:
            update.append((cur["id"], qty, collected, key))
    for key, cur in current.items():
        if key not in wanted:
            remove.append(cur)

    if DRY_RUN:
        for it in add:
            log(f"  + would add {it['scryfall_id']} x{it['desired_quantity']}")
        for _id, qty, coll, key in update:
            log(f"  ~ would set {key[0]} desired={qty} collected={coll}")
        for cur in remove:
            log(f"  - would remove {cur['scryfall_id']}")
        return len(add), len(update), len(remove)

    # Items can only be created through the batch endpoint (max 500/call), and a
    # duplicate against (list_id, scryfall_id, treatment) fails the WHOLE
    # transaction -- `wanted` is keyed on that tuple, so it is duplicate-free.
    for i in range(0, len(add), 400):
        smc(f"/lists/{list_id}/items/batch", "POST", {"items": add[i:i + 400]})
    # collected_quantity is forced to 0 on create, so every new item needs a
    # follow-up PUT to carry ownership.
    fresh = {(it["scryfall_id"], it.get("treatment") or "nonfoil"): it
             for it in list_items(list_id)} if add else {}
    for it in add:
        key = (it["scryfall_id"], it["treatment"])
        collected = collected_by_key.get(key, 0)
        got = fresh.get(key)
        if got and collected:
            smc(f"/lists/{list_id}/items/{got['id']}", "PUT",
                {"desired_quantity": it["desired_quantity"], "collected_quantity": collected})
    for item_id, qty, coll, _key in update:
        smc(f"/lists/{list_id}/items/{item_id}", "PUT",
            {"desired_quantity": qty, "collected_quantity": coll})
    for cur in remove:
        smc(f"/lists/{list_id}/items/{cur['id']}", "DELETE")
    return len(add), len(update), len(remove)


# ── export (ShowMyCards -> files for manual Moxfield upload) ────────────────────

MOX_CSV_HEADERS = ["Count", "Name", "Edition", "Condition", "Language", "Foil",
                   "Collector Number", "Alter", "Playtest Card", "Purchase Price"]


def export_collection(con, path):
    """Moxfield's documented collection CSV. Headers must be spelled exactly as
    above (case-sensitive); order is irrelevant and only Name is mandatory.
    Condition is left blank because ShowMyCards does not track it -- Moxfield's
    import dialog applies its own default rather than us inventing 'Near Mint'."""
    rows = con.execute("""
        select i.quantity, i.treatment,
               json_extract(c.raw_json,'$.name'),
               json_extract(c.raw_json,'$.set'),
               json_extract(c.raw_json,'$.lang'),
               json_extract(c.raw_json,'$.collector_number')
        from inventories i join cards c on c.scryfall_id = i.scryfall_id
        order by 3
    """).fetchall()
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=MOX_CSV_HEADERS, quoting=csv.QUOTE_ALL)
        w.writeheader()
        for qty, treat, name, setcode, lang, cn in rows:
            w.writerow({
                "Count": qty,
                "Name": name,
                "Edition": setcode,
                "Condition": "",
                "Language": LANG_NAME.get(lang, lang or ""),
                # Moxfield accepts only blank / foil / etched here.
                "Foil": "foil" if treat == "foil" else "",
                "Collector Number": cn or "",
                "Alter": "FALSE",
                "Playtest Card": "FALSE",
                "Purchase Price": "",
            })
    return len(rows)


def export_deck(con, list_id, name, path):
    """Moxfield Bulk Edit format: `1 Lightning Bolt (SET) *F*`."""
    lines, non_english = [], 0
    for it in list_items(list_id):
        row = con.execute(
            "select json_extract(raw_json,'$.name'), json_extract(raw_json,'$.set'),"
            " json_extract(raw_json,'$.lang') from cards where scryfall_id = ?",
            (it["scryfall_id"],)).fetchone()
        if not row:
            continue
        cname, setcode, lang = row
        if lang and lang != "en":
            non_english += 1
        foil = " *F*" if (it.get("treatment") == "foil") else ""
        lines.append(f"{it['desired_quantity']} {cname} ({setcode.upper()}){foil}")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    return len(lines), non_english


EXPORT_README = """\
Generated by moxfield-sync on the rpi5. Upload these by hand.

collection.csv  -> https://www.moxfield.com/collection  ("import CSV")
<deck>.txt      -> open the deck on Moxfield, "Bulk Edit", paste into the mainboard box

!! Moxfield's collection import ADDS to your collection, it does NOT replace it.
   Uploading collection.csv twice DOUBLES every quantity, and removals cannot be
   expressed in CSV at all. Treat it as a one-shot seed, not a sync.

!! Moxfield's Bulk Edit cannot add non-English cards. Any French printing in a deck
   .txt will either fail or resolve to the English one. The per-deck line in the run
   summary reports how many non-English cards are affected.

Nothing here is uploaded automatically: Moxfield's write API requires a Bearer token
behind a Cloudflare Turnstile CAPTCHA, and their ToS forbids automated access without
written permission.
"""


# ── main ────────────────────────────────────────────────────────────────────────

def main():
    if not DECK_IDS:
        log("no MOXFIELD_DECK_IDS configured — nothing to do")
        return 0
    os.makedirs(EXPORT_DIR, exist_ok=True)
    os.makedirs(STATE_DIR, exist_ok=True)
    con = open_db()
    owned = owned_by_oracle(con)
    lists = smc("/lists/") or []
    log(f"{len(DECK_IDS)} deck(s) configured, {len(lists)} list(s) in ShowMyCards, "
        f"dry_run={DRY_RUN}")

    totals = {"added": 0, "updated": 0, "removed": 0, "unchanged": 0, "failed": 0}
    for n, public_id in enumerate(DECK_IDS):
        if n:
            time.sleep(FETCH_DELAY)
        try:
            deck = moxfield_deck(public_id)
        except Exception as e:  # noqa: BLE001 - one bad deck must not kill the run
            log(f"{public_id}: FETCH FAILED {e}")
            totals["failed"] += 1
            continue
        name = deck.get("name") or public_id
        wanted, excluded = parse_deck(deck)
        fp = deck_fingerprint(wanted, name)
        state = os.path.join(STATE_DIR, f"{public_id}.hash")
        prev = open(state).read().strip() if os.path.exists(state) else ""

        lst = find_list(lists, public_id, name)
        if lst is None:
            log(f"{name}: no matching list — creating")
            if not DRY_RUN:
                lst = smc("/lists/", "POST",
                          {"name": name, "description": deck.get("publicUrl") or public_id})
                lists.append(lst)
            else:
                log("  (dry-run: skipping create and reconcile)")
                continue
        elif fp == prev:
            log(f"{name}: unchanged on Moxfield — skipping")
            totals["unchanged"] += 1
            continue

        oids = oracle_ids(con, {sid for sid, _ in wanted})
        collected = allocate_collected(wanted, oids, owned)
        added, updated, removed = reconcile(lst["id"], wanted, oids, collected)
        totals["added"] += added
        totals["updated"] += updated
        totals["removed"] += removed
        log(f"{name}: {sum(collected.values())}/{sum(wanted.values())} owned"
            f" — +{added} ~{updated} -{removed}"
            + (f"  (excluded: {excluded})" if excluded else ""))
        if not DRY_RUN:
            with open(state, "w") as fh:
                fh.write(fp)

    # Export direction: always regenerate, it is cheap and read-only.
    csv_path = os.path.join(EXPORT_DIR, "collection.csv")
    n_rows = export_collection(con, csv_path)
    with open(os.path.join(EXPORT_DIR, "README.txt"), "w") as fh:
        fh.write(EXPORT_README)
    exported = []
    for lst in smc("/lists/") or []:
        # Keep accents/apostrophes/commas — these filenames are read by a human.
        # Only strip what breaks a path.
        safe = "".join("_" if ch in '/\\\0' else ch for ch in lst["name"]).strip() or f"list-{lst['id']}"
        cards, non_en = export_deck(con, lst["id"], lst["name"],
                                    os.path.join(EXPORT_DIR, f"{safe}.txt"))
        exported.append((lst["name"], cards, non_en))

    log(f"export: collection.csv {n_rows} rows -> {EXPORT_DIR}")
    for name, cards, non_en in exported:
        warn = f"  ⚠ {non_en} non-English (Bulk Edit cannot add these)" if non_en else ""
        log(f"export: {name}: {cards} lines{warn}")
    log("export: Moxfield collection import ADDS, never replaces — re-uploading "
        "collection.csv doubles quantities")
    log(f"summary: +{totals['added']} ~{totals['updated']} -{totals['removed']} "
        f"unchanged={totals['unchanged']} failed={totals['failed']}"
        + (" [dry-run]" if DRY_RUN else ""))
    return 1 if totals["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
