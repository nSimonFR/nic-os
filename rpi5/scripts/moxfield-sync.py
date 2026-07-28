#!/usr/bin/env python3
"""Mirror Moxfield into ShowMyCards. One direction only.

Moxfield is the single writer for both halves of the data:

  COLLECTION  Moxfield trade binders -> ShowMyCards inventory + storage locations.
              Which binder or box a card sits in is expressed on Moxfield, so
              ShowMyCards no longer owns anything and nothing needs to write to it
              by hand.
  DECKS       Moxfield decks -> ShowMyCards lists, with per-item ownership counts.

There is no push direction. Moxfield's write API needs a Bearer token whose issuing
endpoint (POST /v2/account/token) is gated by a Cloudflare Turnstile CAPTCHA that
cannot be solved server-side -- see the open report from a developer with a
whitelisted User-Agent on Moxfield's own tracker, moxfield/moxfield-public#143 --
and their ToS forbids automated access without written permission.

LANGUAGE IS THE SUBTLE PART. Moxfield does NOT encode language in scryfall_id: it
stores the English printing's id plus a separate `language` attribute, so the same
id legitimately appears twice in one collection, once en and once fr. ShowMyCards'
catalogue uses the language-specific Scryfall printing instead. Mirroring on
Moxfield's id verbatim therefore deletes every French card and re-adds it as the
English printing -- 180-odd rows churned on EVERY run, with the French printing
identity destroyed each time. resolve_printings() maps
(set, collector_number, language) -> the printing ShowMyCards actually stocks, which
is what makes a second consecutive run a no-op.

Ownership (`collected_quantity`) is counted at ORACLE level, not per printing: any
printing in any finish satisfies a deck slot, because what matters is whether the
card is in the box. Printings of one oracle card share one pool within a deck, so
8 Forests wanted across two printings with 5 owned is 5 collected, not 5 + 5.
Pools are NOT shared between decks -- each deck answers "can I build this one",
so a single physical copy legitimately counts in every deck that wants it.

Reconciliation is diff-based (add / update / delete per item) rather than
delete-and-recreate, because ShowMyCards' /api/data/import is additive-only and has
no replace mode: re-importing duplicates everything.

Decks are DISCOVERED per user, not pinned: see discover_decks() for why
showIllegal=true is load-bearing there.

Env contract (all set by rpi5/moxfield-sync.nix):
  MOXFIELD_USERS            comma-separated Moxfield usernames whose decks to sync
  MOXFIELD_COLLECTION_USER  single username whose collection mirrors to inventory
  MOXFIELD_USER_AGENT       honest UA naming the project + a contact URL
  SMC_API                   ShowMyCards API base, e.g. http://127.0.0.1:8330/api
  SMC_DB                    read-only sqlite path, for printing/oracle lookups
  STATE_DIR                 per-deck content hashes, to skip unchanged decks
  DRY_RUN                   "1" (default) logs planned mutations without applying
  FORCE_PRUNE               "1" overrides the mass-deletion guard (see MAX_PRUNE)
"""

import collections
import hashlib
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

MOX_API = "https://api2.moxfield.com/v3/decks/all/"
MOX_SEARCH = "https://api2.moxfield.com/v2/decks/search"
MOX_USER = "https://api2.moxfield.com/v1/users/"
MOX_COLLECTION = "https://api2.moxfield.com/v1/collections/search/"
DECK_BOARDS = ("commanders", "mainboard")  # the deck proper; sideboard/maybeboard reported only
FETCH_DELAY = 3.0  # seconds between Moxfield fetches; their rate limit is unpublished
COLLECTION_PAGE = 500

# Fraction of the existing inventory the mirror may delete in one run before it
# refuses. A binder renamed on Moxfield, a half-migrated collection or a partial
# response all present as "delete most of the inventory", and there is no
# soft-delete anywhere in ShowMyCards to undo it with.
MAX_PRUNE = 0.30

# Moxfield finish -> ShowMyCards treatment.
FINISHES = {"nonFoil": "nonfoil", "foil": "foil", "etched": "etched"}

USERS = [u.strip() for u in os.environ.get("MOXFIELD_USERS", "").split(",") if u.strip()]
COLLECTION_USER = os.environ.get("MOXFIELD_COLLECTION_USER", "").strip()
USER_AGENT = os.environ.get("MOXFIELD_USER_AGENT", "nic-os-moxfield-sync/1.0")
SMC = os.environ.get("SMC_API", "http://127.0.0.1:8330/api").rstrip("/")
DB = os.environ.get("SMC_DB", "/mnt/data/showmycards/database.db")
STATE_DIR = os.environ.get("STATE_DIR", "/var/lib/moxfield-sync")
DRY_RUN = os.environ.get("DRY_RUN", "1") != "0"
FORCE_PRUNE = os.environ.get("FORCE_PRUNE", "0") == "1"


def log(msg):
    print(f"[moxfield-sync] {msg}", flush=True)


# ── HTTP ────────────────────────────────────────────────────────────────────────

class _KeepMethodRedirect(urllib.request.HTTPRedirectHandler):
    """Follow 307/308 without downgrading the method.

    urllib refuses to auto-follow a redirect for anything but GET/HEAD, because a
    301/302 is historically allowed to turn a POST into a GET. 307 and 308 promise
    the opposite — method and body are preserved — so following them is safe, and
    necessary here: ShowMyCards 308s every collection path carrying a trailing slash.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if code in (307, 308):
            return urllib.request.Request(
                newurl, data=req.data, headers=dict(req.header_items()),
                origin_req_host=req.origin_req_host, unverifiable=True,
                method=req.get_method())
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_OPENER = urllib.request.build_opener(_KeepMethodRedirect)


def _request(url, method="GET", body=None, timeout=120, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    hdrs = {"Accept": "application/json"}
    if data:
        hdrs["Content-Type"] = "application/json"
    hdrs.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    with _OPENER.open(req, timeout=timeout) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


def moxfield_get(url, label):
    """GET one Moxfield URL, backing off on 429/5xx. Moxfield publishes no rate
    limit, so be conservative: serial fetches, generous delay, exponential retry."""
    for attempt in range(5):
        try:
            return _request(url, headers={"User-Agent": USER_AGENT})
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt < 4:
                wait = 5 * (2 ** attempt)
                log(f"  {label}: HTTP {e.code}, retrying in {wait}s")
                time.sleep(wait)
                continue
            raise
        except urllib.error.URLError as e:
            if attempt < 4:
                wait = 5 * (2 ** attempt)
                log(f"  {label}: {e.reason}, retrying in {wait}s")
                time.sleep(wait)
                continue
            raise
    raise RuntimeError(f"unreachable: {label}")


def discover_decks(users):
    """-> [(public_id, name, author)] for every deck authored by any of `users`.

    `showIllegal=true` is LOAD-BEARING, not a tweak. The search default hides decks
    Moxfield considers illegal, and that silently dropped 2 of this user's 5 decks
    — including a 94-card commander deck that is simply mid-build. A deck under
    construction is precisely the one you want synced (it is the shopping list), so
    the default filter is backwards for our purpose. Omitting this flag is what
    made an earlier version of this file conclude discovery was unreliable and pin
    deck ids by hand; it was never an index gap.

    The filter matches AUTHORS, not just the creator, so a deck someone else made
    with our user as co-author is included — which is why results are deduped by
    publicId rather than concatenated.
    """
    seen, out = set(), []
    for user in users:
        page = 1
        while True:
            q = urllib.parse.urlencode({
                "authorUserNames": user, "pageNumber": page,
                "pageSize": 100, "showIllegal": "true",
            })
            data = _request(f"{MOX_SEARCH}?{q}", headers={"User-Agent": USER_AGENT})
            rows = data.get("data") or []
            for d in rows:
                pid = d.get("publicId")
                if not pid or pid in seen:
                    continue
                seen.add(pid)
                out.append((pid, d.get("name") or pid,
                            (d.get("createdByUser") or {}).get("userName") or "?"))
            # totalPages is absent on some responses; the empty page is the real
            # terminator, the page cap just stops a pathological loop.
            if not rows or page >= data.get("totalPages", page) or page >= 20:
                break
            page += 1
            time.sleep(FETCH_DELAY)
        time.sleep(FETCH_DELAY)
    return out


def moxfield_deck(public_id):
    return moxfield_get(MOX_API + public_id, public_id)


def moxfield_collection(user):
    """-> [row] for the user's whole collection.

    The collection id is resolved from the profile rather than hardcoded, which also
    surfaces `collectionVisibility`: this endpoint only works while the collection is
    public, and a flip to private must fail loudly rather than read as "the user owns
    nothing" — that would delete the entire ShowMyCards inventory.
    """
    profile = moxfield_get(MOX_USER + urllib.parse.quote(user), f"user {user}")
    vis = profile.get("collectionVisibility")
    cid = profile.get("collectionPublicId")
    if vis != "public" or not cid:
        raise RuntimeError(
            f"collection of {user} is not publicly readable (visibility={vis!r}, "
            f"id={cid!r}) — set it to public on Moxfield or disable the mirror")

    rows, page = [], 1
    while True:
        q = urllib.parse.urlencode({"pageNumber": page, "pageSize": COLLECTION_PAGE})
        data = moxfield_get(f"{MOX_COLLECTION}{cid}?{q}", f"collection p{page}")
        rows += data.get("data") or []
        total = data.get("totalResults")
        if page >= (data.get("totalPages") or 1):
            break
        page += 1
        time.sleep(FETCH_DELAY)

    # A truncated response reads as "these cards were sold" and would prune them.
    if total is not None and len(rows) != total:
        raise RuntimeError(f"collection truncated: got {len(rows)} rows, expected {total}")
    if not rows:
        raise RuntimeError("collection came back empty — refusing to prune everything")
    return rows


def smc(path, method="GET", body=None):
    # A trailing slash on a collection path (/api/inventory/, /api/lists/) is 308ed
    # to the bare form. _KeepMethodRedirect makes that survivable, but it is still a
    # wasted round trip on every call, so normalise it away here.
    path = path.replace("/?", "?", 1)
    if path.endswith("/"):
        path = path[:-1]
    # First call after idle wakes the socket-activated chain and waits on the
    # ready probe, which can take ~60s -- hence the long timeout.
    return _request(f"{SMC}{path}", method=method, body=body, timeout=180)


def smc_paged(path):
    """Walk a `{data, total_pages}` envelope. Pagination is page/page_size, never
    limit/offset, and /inventory/ caps page_size at 100."""
    out, page = [], 1
    sep = "&" if "?" in path else "?"
    while True:
        resp = smc(f"{path}{sep}page={page}&page_size=100")
        out += resp.get("data") or []
        if page >= (resp.get("total_pages") or 1):
            return out
        page += 1


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
    card in it was sitting in a binder.

    Written as a correlated lookup rather than the obvious `inventories JOIN cards`
    because that join does not finish. SQLite sees `group by c.oracle_id`, picks
    idx_cards_oracle_id to get the grouping for free, and drives the whole query from
    `cards` — walking all 171k rows of a table carrying 668 MB of raw_json to reach
    the ~500 that inventories actually references. Measured: >3 min and still going,
    versus 5 s for this form, which scans the small table and does one primary-key
    lookup per row.
    """
    owned = {}
    for oid, qty in con.execute(
        "select oracle_id, sum(quantity) from ("
        "  select (select oracle_id from cards where scryfall_id = i.scryfall_id)"
        "         as oracle_id, i.quantity as quantity"
        "  from inventories i"
        ") where oracle_id is not null group by 1"
    ):
        owned[oid] = qty
    return owned


def _cn(value):
    """Collector numbers are strings ('12a', '★'), but leading zeros differ between
    sources, so normalise only that."""
    s = str(value or "").strip()
    return s.lstrip("0") or s


def resolve_printings(con, rows, oids):
    """-> {(set, collector_number, lang): scryfall_id} for the NON-ENGLISH rows only.

    Scoped tightly on purpose. `raw_json` holds the whole Scryfall blob, so any query
    that json_extracts across a broad row set drags the entire card record off disk.
    Doing that per set (85 sets, ~60k cards) cost 2.8 GB of reads for 13 s of CPU and
    thrashed a box with 3.9 GB of RAM; a single `set_code IN (85 values)` scan does
    not finish inside two minutes at all.

    Pivoting to the indexed `oracle_id` shrinks it to the printings of the ~150 cards
    that can actually move: language variants of one card share an oracle_id, a set
    and a collector number, differing only in `lang`. English rows need no lookup —
    Moxfield already reports the English printing's id (empirically every one of the
    182 remaps is a French row).
    """
    idx = {}
    targets = sorted({
        oids[(r.get("card") or {}).get("scryfall_id")]
        for r in rows
        if ((r.get("language") or {}).get("code") or "en") != "en"
        and (r.get("card") or {}).get("scryfall_id") in oids})
    for i in range(0, len(targets), 200):
        chunk = targets[i:i + 200]
        for sid, code, cn, lang in con.execute(
            "select scryfall_id, set_code, json_extract(raw_json,'$.collector_number'),"
            f" json_extract(raw_json,'$.lang') from cards"
            f" where oracle_id in ({','.join('?' * len(chunk))})", chunk
        ):
            if cn is not None and lang:
                idx[(code, _cn(cn), lang)] = sid
    return idx


# ── collection mirror (Moxfield -> ShowMyCards inventory) ───────────────────────

def infer_storage_type(name):
    """Moxfield has no Box-vs-Binder distinction and ShowMyCards requires one, so the
    name is the only signal there is. It is cosmetic in ShowMyCards — it picks an
    icon, nothing more — so a wrong guess costs an icon, not data. Correct for all
    eight binders in use ("Big Box"/"Green Deck Box" are the only Boxes)."""
    return "Box" if "box" in (name or "").lower() else "Binder"


def sync_storage_locations(rows):
    """-> {binder publicId: showmycards storage_location_id}

    Locations follow Moxfield instead of being declared in config. Binders get
    created on first sight and renamed when Moxfield renames them, so adding or
    renaming one costs no config edit and no rebuild — which matters, because these
    names turn out to change constantly ("Magic Big Box" -> "Big Box",
    "EDH 2013 - Alfie" -> "EDH - Alfie" -> "EDH - Errant" inside one afternoon).

    The publicId -> location id link is kept in STATE_DIR because ShowMyCards storage
    has no field to hold a foreign id, and names cannot serve as the link: the whole
    point is that they change. On a cold state file the name is used once to adopt
    existing locations, so a rebuilt state re-attaches instead of duplicating.

    Locations with no matching binder are left alone — they may be the user's own,
    and DELETE /storage/:id is guarded by referential integrity anyway.
    """
    binders = {}
    for r in rows:
        b = r.get("tradeBinder") or {}
        if b.get("publicId"):
            binders[b["publicId"]] = b.get("name") or b["publicId"]

    state_path = os.path.join(STATE_DIR, "binders.json")
    state = {}
    if os.path.exists(state_path):
        try:
            state = json.load(open(state_path))
        except Exception:  # noqa: BLE001 - a corrupt state file must not wedge the sync
            log("  ! binders.json unreadable — re-adopting locations by name")

    current = {s["id"]: s for s in (smc("/storage/with-counts") or [])}
    by_name = {s["name"]: s for s in current.values()}

    out, changed = {}, False
    for pid, name in sorted(binders.items(), key=lambda kv: kv[1]):
        loc = current.get(state.get(pid)) or by_name.get(name)
        if loc is None:
            typ = infer_storage_type(name)
            if DRY_RUN:
                log(f"  + would create storage location {name!r} ({typ})")
                continue
            loc = smc("/storage", "POST", {"name": name, "storage_type": typ})
            log(f"  + created storage location {name!r} ({typ})")
        elif (loc.get("name") or "") != name:
            log(f"  ~ storage location {loc['name']!r} renamed on Moxfield -> {name!r}")
            if not DRY_RUN:
                # storage_type is a non-pointer field — omitting it writes an empty
                # value, the same trap as description on PUT /lists/:id.
                smc(f"/storage/{loc['id']}", "PUT",
                    {"name": name, "storage_type": loc["storage_type"]})
        out[pid] = loc["id"]
        if state.get(pid) != loc["id"]:
            state[pid] = loc["id"]
            changed = True

    if changed and not DRY_RUN:
        with open(state_path, "w") as fh:
            json.dump(state, fh, indent=2, sort_keys=True)
    return out


def build_wanted_inventory(con, rows):
    """-> ({(scryfall_id, treatment, location_id): qty}, stats)

    Collapses by summing: several Moxfield rows legitimately map to one ShowMyCards
    row, because ShowMyCards' inventory has no language and no condition column. The
    en/fr pair of one printing in one binder is exactly that case.
    """
    locations = sync_storage_locations(rows)

    # Doubles as the catalogue-membership test: oracle_ids() only returns ids that
    # exist locally with an oracle_id, and an id without one cannot be POSTed anyway.
    # It reads no raw_json, so it stays cheap over all 515 rows.
    known = oracle_ids(con, {s for s in
                             ((r.get("card") or {}).get("scryfall_id") for r in rows) if s})
    idx = resolve_printings(con, rows, known)

    wanted = collections.Counter()
    stats = {"remapped": 0, "unresolved": 0, "no_binder": 0, "bad_finish": 0}
    unresolved = []
    for r in rows:
        card = r.get("card") or {}
        mox_sid = card.get("scryfall_id")
        if not mox_sid:
            continue
        lang = ((r.get("language") or {}).get("code") or "en")
        sid = idx.get((card.get("set"), _cn(card.get("cn")), lang))
        if sid is None:
            # English row, or no printing in that language: keep whatever id Moxfield
            # gave, but only if we actually stock it. The catalogue is en+fr only
            # (see pkgs/showmycards.nix), so anything else is unrepresentable.
            if mox_sid not in known:
                stats["unresolved"] += 1
                if len(unresolved) < 10:
                    unresolved.append(f"{card.get('name')} [{card.get('set')} "
                                      f"{card.get('cn')} {lang}]")
                continue
            sid = mox_sid
        elif sid != mox_sid:
            stats["remapped"] += 1

        finish = r.get("finish")
        treat = FINISHES.get(finish)
        if treat is None:
            stats["bad_finish"] += 1
            log(f"  ! unknown finish {finish!r} on {card.get('name')} — treating as nonfoil")
            treat = "nonfoil"

        binder = (r.get("tradeBinder") or {}).get("publicId")
        if binder is None:
            stats["no_binder"] += 1
        wanted[(sid, treat, locations.get(binder))] += int(r.get("quantity") or 0)

    for u in unresolved:
        log(f"  ! not in local en+fr catalogue: {u}")
    if stats["no_binder"]:
        log(f"  ! {stats['no_binder']} card(s) in no Moxfield binder — left unassigned")
    return dict(wanted), stats


def mirror_inventory(con, rows):
    """Bring ShowMyCards inventory in line with the Moxfield collection.
    Returns (added, updated, removed) or None if the guard refused."""
    wanted, stats = build_wanted_inventory(con, rows)

    current = collections.defaultdict(list)
    for it in smc_paged("/inventory/"):
        current[(it["scryfall_id"], it.get("treatment") or "nonfoil",
                 it.get("storage_location_id"))].append(it)

    oids = oracle_ids(con, {sid for sid, _, _ in wanted})

    add, update, remove = [], [], []
    for key, qty in wanted.items():
        sid, treat, loc = key
        oid = oids.get(sid)
        if not oid:
            # oracle_id is mandatory on POST and external sources omit it.
            log(f"  ! {sid} has no oracle_id locally — skipping")
            continue
        held = current.get(key) or []
        if not held:
            add.append({"scryfall_id": sid, "oracle_id": oid, "treatment": treat,
                        "quantity": qty, "storage_location_id": loc})
        else:
            # Several rows for one key means the collection was hand-edited or
            # double-imported; keep the first and drop the rest.
            keep, dupes = held[0], held[1:]
            if keep["quantity"] != qty:
                update.append((keep, qty))
            remove += dupes
    for key, held in current.items():
        if key not in wanted:
            remove += held

    total_now = sum(it["quantity"] for its in current.values() for it in its)
    pruned = sum(it["quantity"] for it in remove)
    log(f"inventory: moxfield {sum(wanted.values())} cards in {len(wanted)} rows"
        f" | showmycards {total_now} in {sum(len(v) for v in current.values())}"
        f" | remapped {stats['remapped']} printing(s) to their fr/en variant")
    log(f"inventory: +{len(add)} ~{len(update)} -{len(remove)}"
        + (" [dry-run]" if DRY_RUN else ""))

    if total_now and pruned > total_now * MAX_PRUNE and not FORCE_PRUNE:
        log(f"inventory: REFUSING — would delete {pruned}/{total_now} cards "
            f"(>{int(MAX_PRUNE * 100)}%). A renamed binder or a partial Moxfield "
            f"collection looks exactly like this. Set FORCE_PRUNE=1 if intended.")
        return None

    if DRY_RUN:
        for it in add[:20]:
            log(f"  + would add {it['scryfall_id']} x{it['quantity']} @loc {it['storage_location_id']}")
        for cur, qty in update[:20]:
            log(f"  ~ would set {cur['scryfall_id']} qty {cur['quantity']} -> {qty}")
        for cur in remove[:20]:
            log(f"  - would remove {cur['scryfall_id']} x{cur['quantity']} @loc {cur.get('storage_location_id')}")
        if max(len(add), len(update), len(remove)) > 20:
            log("  … (truncated to 20 per category)")
        return len(add), len(update), len(remove)

    for it in add:
        smc("/inventory/", "POST", it)
    # Send the whole row, not just the quantity: ShowMyCards' update handlers write
    # non-pointer fields unconditionally, so a partial PUT is how you silently blank
    # storage_location_id (the same trap as PUT /lists/:id wiping description).
    for cur, qty in update:
        smc(f"/inventory/{cur['id']}", "PUT", {
            "scryfall_id": cur["scryfall_id"], "oracle_id": cur["oracle_id"],
            "treatment": cur.get("treatment") or "nonfoil", "quantity": qty,
            "storage_location_id": cur.get("storage_location_id"),
        })
    delete_inventory([it["id"] for it in remove])
    return len(add), len(update), len(remove)


def delete_inventory(ids):
    """Batch delete, falling back to one-by-one. The batch route is a DELETE with a
    JSON body capped at 1000 ids; if that shape is rejected, the per-id route is
    slower but always available."""
    for i in range(0, len(ids), 500):
        chunk = ids[i:i + 500]
        try:
            smc("/inventory/batch", "DELETE", {"ids": chunk})
        except urllib.error.HTTPError as e:
            log(f"  batch delete rejected ({e.code}) — falling back to per-id")
            for one in chunk:
                smc(f"/inventory/{one}", "DELETE")


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


def deck_fingerprint(wanted, name, inventory_fp):
    """The inventory fingerprint is part of this on purpose: a deck untouched on
    Moxfield still needs its collected_quantity refreshed when the collection moves
    underneath it, and the mirror moves it daily. Without this the hash-skip below
    would freeze every ownership count at whatever it was when the deck last changed."""
    payload = json.dumps({"n": name, "i": inventory_fp,
                          "c": sorted([[k[0], k[1], v] for k, v in wanted.items()])},
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


# ── ShowMyCards deck reconciliation ─────────────────────────────────────────────

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
    return smc_paged(f"/lists/{list_id}/items")


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


# ── main ────────────────────────────────────────────────────────────────────────

def sync_collection():
    """-> True if the inventory is in a known-good state to reconcile decks against."""
    if not COLLECTION_USER:
        log("no MOXFIELD_COLLECTION_USER configured — skipping collection mirror")
        return True
    try:
        rows = moxfield_collection(COLLECTION_USER)
    except Exception as e:  # noqa: BLE001
        # Same reasoning as deck discovery: a partial or failed read is
        # indistinguishable from "the user sold everything".
        log(f"collection fetch FAILED for {COLLECTION_USER}: {e} — inventory untouched")
        return False
    log(f"collection: {len(rows)} rows from {COLLECTION_USER}")
    con = open_db()
    try:
        return mirror_inventory(con, rows) is not None
    except Exception as e:  # noqa: BLE001
        log(f"collection mirror FAILED: {e} — inventory untouched")
        return False
    finally:
        con.close()


def main():
    if not USERS:
        log("no MOXFIELD_USERS configured — nothing to do")
        return 0
    os.makedirs(STATE_DIR, exist_ok=True)

    # Inventory first: deck ownership counts are computed from it, so mirroring
    # afterwards would report every deck against yesterday's collection.
    mirror_ok = sync_collection()

    # Reopen after the mirror so this connection sees the committed writes — the
    # backend holds the WAL writer and this one is read-only.
    con = open_db()
    owned = owned_by_oracle(con)
    inventory_fp = hashlib.sha256(
        json.dumps(sorted(owned.items()), sort_keys=True).encode()).hexdigest()
    lists = smc("/lists/") or []

    try:
        found = discover_decks(USERS)
    except Exception as e:  # noqa: BLE001
        # Discovery is the whole input set: a partial list would read as "these
        # decks were deleted on Moxfield" and reconcile would empty the lists.
        log(f"discovery FAILED for {','.join(USERS)}: {e} — aborting without changes")
        return 1
    decks = [(pid, name) for pid, name, _ in found]
    for pid, name, author in found:
        log(f"  deck: {name} ({pid}, by {author})")
    log(f"{len(decks)} deck(s) from {len(USERS)} user(s), {len(lists)} list(s) in "
        f"ShowMyCards, dry_run={DRY_RUN}")

    totals = {"added": 0, "updated": 0, "removed": 0, "unchanged": 0, "failed": 0}
    for n, (public_id, _discovered_name) in enumerate(decks):
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
        fp = deck_fingerprint(wanted, name, inventory_fp)
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

        # Moxfield owns the name too, and decks do get renamed — the list is matched
        # on the publicId in its description, so a rename is silent drift otherwise.
        if (lst.get("name") or "").strip() != name.strip():
            log(f"{lst['name']}: renamed on Moxfield -> {name}")
            if not DRY_RUN:
                # description MUST be resent: it is a non-pointer field, so omitting
                # it blanks the Moxfield URL find_list matches on next run.
                smc(f"/lists/{lst['id']}", "PUT", {
                    "name": name,
                    "description": lst.get("description") or deck.get("publicUrl") or public_id,
                })

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

    con.close()
    log(f"summary: decks +{totals['added']} ~{totals['updated']} -{totals['removed']} "
        f"unchanged={totals['unchanged']} failed={totals['failed']} "
        f"collection={'ok' if mirror_ok else 'FAILED'}"
        + (" [dry-run]" if DRY_RUN else ""))
    return 0 if (mirror_ok and not totals["failed"]) else 1


if __name__ == "__main__":
    sys.exit(main())
